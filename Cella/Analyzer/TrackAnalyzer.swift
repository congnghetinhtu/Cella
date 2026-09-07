//
//  TrackAnalyzer.swift
//  Cella
//
//  On-device audio analysis using spfk-tempo, spfk-musical-analysis, and spfk-loudness.
//  Includes spectral feature extraction, vocal boundary detection, and structure analysis.
//

import AVFoundation
import Accelerate
import SPFKTempo
import SPFKMusicalAnalysis
import SPFKLoudness
import SPFKAudioBase

/// Performs music analysis on audio files using spfk-* packages.
/// Runs as an actor for thread-safe concurrent analysis.
actor TrackAnalyzer {
    private let config: AudioConfig

    init(config: AudioConfig = .standard) {
        self.config = config
    }

    /// Analyzes a single audio file and returns its analysis results.
    /// Uses disk cache (.cellax) when available and valid.
    func analyze(url: URL) async throws -> TrackAnalysis {
        // Check cache first — fastest path
        if let cached = AnalysisCache.load(for: url) {
            return cached
        }

        // Run BPM, Key, Loudness in parallel (each reads file independently)
        async let bpmResult: Double? = detectBPM(url: url)
        async let keyResult: TrackAnalysis.KeySignature? = detectKey(url: url)
        async let loudnessResult: LoudnessDescription? = detectLoudness(url: url)

        // Read + downsample audio while spfk-* runs in parallel
        let audioFile = try AudioHelpers.readAudio(url: url)
        let totalFrames = AVAudioFrameCount(audioFile.length)
        let targetSampleRate: Double = 22050

        let originalBuffer: AVAudioPCMBuffer
        if let buf = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: totalFrames) {
            buf.frameLength = totalFrames
            try audioFile.read(into: buf, frameCount: totalFrames)
            originalBuffer = buf
        } else if let fallback = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: 1) {
            originalBuffer = fallback
        } else {
            return emptyAnalysis()
        }

        let buffer = downsampleToMono(originalBuffer, targetSampleRate: targetSampleRate)

        // Await parallel results
        let bpm = try? await bpmResult
        let keySignature = try? await keyResult
        let loudnessDesc = try? await loudnessResult

        // Shared FFT setup for vocal detection + vocal activity (reuse across both)
        let mono = buffer.floatChannelData![0]
        let frameLength = Int(buffer.frameLength)
        let sampleRate = Float(buffer.format.sampleRate)
        let fftWindow = 4096
        let log2n = vDSP_Length(log2(Float(fftWindow)))
        let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        // Compute all buffer-based features in one pass
        let energyProfile = AudioHelpers.getRMSProfile(buffer: buffer, windowSize: 8192)
        let structureSections = detectSections(energyProfile: energyProfile, duration: audioFile.duration)
        let introOutro = detectIntroOutro(structureSections: structureSections)
        let spectral = AudioHelpers.computeSpectralFeatures(buffer: buffer)
        let avgRMS = averageEnergy(energyProfile)
        let peakAmp = AudioHelpers.peakAmplitude(buffer: buffer)
        let beatInfo = AudioHelpers.detectBeats(buffer: buffer, bpm: bpm ?? 0)
        let beatTimestamps = beatInfo.beats
        let bpb = detectBarsPerBeat(beatTimestamps: beatTimestamps, bpm: bpm ?? 120)
        let barTimestamps = stride(from: 0, to: beatTimestamps.count, by: bpb).map { beatTimestamps[$0] }

        // Vocal detection — share FFT setup
        let hasVocals: Bool
        let vocalActivity: [Float]
        let vocalBoundaries: (onsets: [Double], offsets: [Double])

        if let setup = fftSetup {
            hasVocals = detectVocals(buffer: buffer, fftSetup: setup, log2n: log2n)
            vocalActivity = detectVocalActivity(buffer: buffer, fftSetup: setup, log2n: log2n)
            vocalBoundaries = AudioHelpers.detectVocalBoundaries(buffer: buffer)
            vDSP_destroy_fftsetup(setup)
        } else {
            hasVocals = false
            vocalActivity = []
            vocalBoundaries = ([], [])
        }

        let result = TrackAnalysis(
            bpm: bpm,
            beatTimestamps: beatTimestamps,
            barTimestamps: barTimestamps,
            keySignature: keySignature,
            loudnessIntegrated: loudnessDesc?.loudnessIntegrated,
            structureSections: structureSections,
            energyProfile: energyProfile,
            hasVocals: hasVocals,
            vocalActivity: vocalActivity,
            duration: audioFile.duration,
            spectralCentroid: spectral.centroid,
            spectralRolloff: spectral.rolloff,
            spectralBandwidth: spectral.bandwidth,
            spectralFlatness: spectral.flatness,
            averageRMS: Float(avgRMS),
            peakAmplitude: peakAmp,
            introRegion: introOutro.intro.map { TrackAnalysis.Region(start: $0.start, end: $0.end) },
            outroRegion: introOutro.outro.map { TrackAnalysis.Region(start: $0.start, end: $0.end) },
            vocalOnsetTimestamps: vocalBoundaries.onsets,
            vocalOffsetTimestamps: vocalBoundaries.offsets
        )

        AnalysisCache.save(result, for: url)
        return result
    }

    /// Analyzes multiple files concurrently, yielding progress updates.
    func analyzeAll(
        assets: [TrackAsset],
        maxConcurrent: Int = 3,
        progressHandler: @Sendable (Int, Int, TrackAsset) -> Void
    ) async throws -> [TrackAsset] {
        var results = assets
        let total = assets.count
        var completed = 0

        print("[Analyzer] analyzeAll started: \(total) tracks, maxConcurrent=\(maxConcurrent)")

        var index = 0
        while index < total {
            let batchEnd = min(index + maxConcurrent, total)
            let batch = Array(index..<batchEnd)

            await withTaskGroup(of: (Int, TrackAsset).self) { group in
                for batchIndex in batch {
                    group.addTask { [self] in
                        var asset = assets[batchIndex]
                        do {
                            let analysis = try await self.analyze(url: asset.url)
                            asset.analysis = analysis
                            print("[Analyzer] ✓ \(asset.fileName) — bpm=\(String(describing: analysis.bpm)), spectral=\(String(format: "%.1f", analysis.spectralCentroid))Hz, vocals=\(analysis.hasVocals)")
                        } catch {
                            print("[Analyzer] ✗ \(asset.fileName) — FAILED: \(error.localizedDescription)")
                        }
                        return (batchIndex, asset)
                    }
                }

                for await (batchIndex, asset) in group {
                    results[batchIndex] = asset
                    completed += 1
                    progressHandler(completed, total, asset)
                }
            }

            index = batchEnd
        }

        return results
    }

    // MARK: - BPM Detection (spfk-tempo)

    private func detectBPM(url: URL) async throws -> Double? {
        let origErr = dup(STDERR_FILENO)
        let devNull = open("/dev/null", O_WRONLY)
        dup2(devNull, STDERR_FILENO)
        close(devNull)

        let bpm: Double?
        do {
            let analysis = try BpmAnalysis(url: url)
            let result = try await analysis.process()
            bpm = result?.rawValue
        } catch {
            bpm = nil
        }

        dup2(origErr, STDERR_FILENO)
        close(origErr)

        guard let value = bpm, value > 0 else { return nil }
        return value
    }

    // MARK: - Key Detection (spfk-musical-analysis)

    private func detectKey(url: URL) async throws -> TrackAnalysis.KeySignature? {
        let analysis = try MusicalKeyAnalysis(url: url)
        let keyValue = try await analysis.process()
        let tonic = keyValue.name.description
        let mode = keyValue.tonality == .minor ? "minor" : "major"
        return TrackAnalysis.KeySignature(tonic: tonic, mode: mode)
    }

    // MARK: - Loudness Detection (spfk-loudness)

    private func detectLoudness(url: URL) async throws -> LoudnessDescription? {
        try LoudnessAnalyzer.analyze(url: url, minimumDuration: 5)
    }

    // MARK: - Structure Detection (energy-based)

    private func detectSections(energyProfile: [Float], duration: Double) -> [TrackAnalysis.StructureSection] {
        guard energyProfile.count >= 4 else { return [] }

        let windowDuration = duration / Double(energyProfile.count * 2)
        var sections: [TrackAnalysis.StructureSection] = []
        var sectionStart = 0
        var prevEnergy = energyProfile[0]

        for i in 1..<energyProfile.count {
            let energyDiff = abs(energyProfile[i] - prevEnergy)
            if energyDiff > 0.2 {
                let startTime = Double(sectionStart) * windowDuration * 2
                let endTime = Double(i) * windowDuration * 2
                let avgEnergy = averageRange(energyProfile, from: sectionStart, to: i)
                let label = classifySection(avgEnergy: avgEnergy)
                sections.append(TrackAnalysis.StructureSection(startTime: startTime, endTime: endTime, label: label))
                sectionStart = i
            }
            prevEnergy = energyProfile[i]
        }

        let startTime = Double(sectionStart) * windowDuration * 2
        if startTime < duration {
            let avgEnergy = averageRange(energyProfile, from: sectionStart, to: energyProfile.count)
            let label = classifySection(avgEnergy: avgEnergy)
            sections.append(TrackAnalysis.StructureSection(startTime: startTime, endTime: duration, label: label))
        }

        return sections
    }

    private func averageRange(_ array: [Float], from start: Int, to end: Int) -> Float {
        guard start < end, end <= array.count else { return 0 }
        let slice = Array(array[start..<end])
        return slice.reduce(0, +) / Float(slice.count)
    }

    private func classifySection(avgEnergy: Float) -> String {
        switch avgEnergy {
        case 0..<0.05: return "silence"
        case 0.05..<0.15: return "intro"
        case 0.15..<0.3: return "verse"
        case 0.3..<0.5: return "chorus"
        case 0.5..<0.7: return "bridge"
        default: return "outro"
        }
    }

    // MARK: - Intro/Outro Detection

    private func detectIntroOutro(
        structureSections: [TrackAnalysis.StructureSection]
    ) -> (intro: (start: Double, end: Double)?, outro: (start: Double, end: Double)?) {
        var intro: (start: Double, end: Double)?
        var outro: (start: Double, end: Double)?

        for section in structureSections {
            if section.label == "intro" || section.label == "silence" {
                if intro == nil {
                    intro = (start: section.startTime, end: section.endTime)
                } else {
                    intro = (start: intro!.start, end: section.endTime)
                }
            }
            if section.label == "outro" || section.label == "silence" {
                outro = (start: section.startTime, end: section.endTime)
            }
        }

        return (intro, outro)
    }

    // MARK: - Vocal Detection (spectral analysis) — accepts shared FFTSetup

    private func detectVocals(buffer: AVAudioPCMBuffer, fftSetup: FFTSetup, log2n: vDSP_Length) -> Bool {
        guard let channelData = buffer.floatChannelData else { return false }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 4096 else { return false }

        let mono = channelData[0]
        let sampleRate = Float(buffer.format.sampleRate)
        let windowSize = 4096

        let regionSize = min(frameLength / 3, windowSize)
        let regions = [
            (start: 0, end: regionSize),
            (start: frameLength / 3, end: frameLength / 3 + regionSize),
            (start: max(0, frameLength - regionSize), end: frameLength)
        ]

        var vocalVotes = 0
        var totalVotes = 0

        for region in regions {
            let regionLength = region.end - region.start
            guard regionLength > 1024 else { continue }

            var crossings = 0
            for i in (region.start + 1)..<region.end {
                if (mono[i] >= 0) != (mono[i-1] >= 0) {
                    crossings += 1
                }
            }
            let zcr = Float(crossings) / Float(regionLength)

            var rms: Float = 0
            vDSP_rmsqv(mono + region.start, 1, &rms, vDSP_Length(regionLength))

            let centroid = AudioHelpers.computeWindowSpectralCentroid(
                data: mono + region.start,
                frameCount: regionLength,
                sampleRate: sampleRate,
                fftSetup: fftSetup,
                log2n: log2n
            )

            let zcrOK = zcr > 0.01 && zcr < 0.30
            let centroidOK = centroid > 250 && centroid < 7000
            let rmsOK = rms > 0.005

            totalVotes += 1
            if zcrOK && centroidOK && rmsOK {
                vocalVotes += 1
            }
        }

        return vocalVotes >= 1
    }

    /// Detects per-window vocal activity — accepts shared FFTSetup.
    private func detectVocalActivity(buffer: AVAudioPCMBuffer, fftSetup: FFTSetup, log2n: vDSP_Length) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 4096 else { return [] }

        let mono = channelData[0]
        let sampleRate = Float(buffer.format.sampleRate)
        let windowSize = 4096
        let hopSize = 4096

        var activity = [Float]()
        activity.reserveCapacity(frameLength / hopSize)
        var position = 0

        while position + windowSize <= frameLength {
            var rms: Float = 0
            vDSP_rmsqv(mono + position, 1, &rms, vDSP_Length(windowSize))

            var crossings: vDSP_Length = 0
            for i in 1..<windowSize {
                if (mono[position + i] >= 0) != (mono[position + i - 1] >= 0) {
                    crossings += 1
                }
            }
            let zcr = Float(crossings) / Float(windowSize)

            let centroid = AudioHelpers.computeWindowSpectralCentroid(
                data: mono + position,
                frameCount: windowSize,
                sampleRate: sampleRate,
                fftSetup: fftSetup,
                log2n: log2n
            )

            var score: Float = 0
            if rms > 0.004 {
                let centroidLow: Float = 300
                let centroidHigh: Float = 6000
                let centroidMid = (centroidLow + centroidHigh) / 2.0
                let centroidRange = centroidHigh - centroidLow
                let centroidDist = abs(centroid - centroidMid) / (centroidRange / 2.0)
                let centroidScore = exp(-centroidDist * centroidDist * 1.2)

                let zcrMid: Float = 0.12
                let zcrRange: Float = 0.20
                let zcrDist = abs(zcr - zcrMid) / (zcrRange / 2.0)
                let zcrScore = exp(-zcrDist * zcrDist * 1.2)

                let energyScore = min(1.0, rms * 4.0)
                score = (centroidScore * 0.4 + zcrScore * 0.35 + energyScore * 0.25)
                if centroid < 150 { score *= 0.6 }
                if centroid > 7000 { score *= 0.7 }
                if zcr < 0.003 { score *= 0.6 }
                if zcr > 0.32 { score *= 0.8 }
            }

            activity.append(min(1.0, max(0.0, score)))
            position += hopSize
        }

        return activity
    }

    // MARK: - Downsampling

    private func downsampleToMono(_ buffer: AVAudioPCMBuffer, targetSampleRate: Double) -> AVAudioPCMBuffer {
        let originalRate = buffer.format.sampleRate
        let originalFrames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        guard let channelData = buffer.floatChannelData else { return buffer }
        var mono = [Float](repeating: 0, count: originalFrames)
        if channelCount >= 2 {
            var scale: Float = 0.5
            vDSP_vadd(channelData[0], 1, channelData[1], 1, &mono, 1, vDSP_Length(originalFrames))
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(originalFrames))
        } else {
            mono.withUnsafeMutableBufferPointer { dest in
                guard let dst = dest.baseAddress else { return }
                channelData[0].withMemoryRebound(to: Float.self, capacity: originalFrames) { src in
                    dst.update(from: src, count: originalFrames)
                }
            }
        }

        let outputRate = min(originalRate, targetSampleRate)
        let ratio = originalRate / outputRate
        let downsampledFrames = Int(Double(originalFrames) / ratio)
        guard downsampledFrames > 0 else { return buffer }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputRate,
            channels: 1,
            interleaved: false
        ), let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(downsampledFrames)) else {
            return buffer
        }

        output.frameLength = AVAudioFrameCount(downsampledFrames)
        guard let outData = output.floatChannelData else { return buffer }

        for i in 0..<downsampledFrames {
            let srcIdx = min(originalFrames - 1, Int(Double(i) * ratio))
            outData[0][i] = mono[srcIdx]
        }

        return output
    }

    // MARK: - Utility

    private func averageEnergy(_ profile: [Float]) -> Double {
        guard !profile.isEmpty else { return 0 }
        let sum = profile.reduce(0, +)
        return Double(sum) / Double(profile.count)
    }

    private func detectBarsPerBeat(beatTimestamps: [Double], bpm: Double) -> Int {
        guard beatTimestamps.count >= 12 else { return 4 }
        let beatInterval = 60.0 / bpm
        var score4 = 0, score3 = 0
        for i in stride(from: 0, to: min(beatTimestamps.count, 48), by: 1) {
            let mod4 = beatTimestamps[i].truncatingRemainder(dividingBy: beatInterval * 4)
            let mod3 = beatTimestamps[i].truncatingRemainder(dividingBy: beatInterval * 3)
            if mod4 < beatInterval * 0.5 { score4 += 1 }
            if mod3 < beatInterval * 0.5 { score3 += 1 }
        }
        return score3 > score4 ? 3 : 4
    }

    private func emptyAnalysis() -> TrackAnalysis {
        TrackAnalysis(
            bpm: nil, beatTimestamps: [], barTimestamps: [], keySignature: nil,
            loudnessIntegrated: nil, structureSections: [], energyProfile: [],
            hasVocals: false, vocalActivity: [], duration: 0,
            spectralCentroid: 0, spectralRolloff: 0, spectralBandwidth: 0, spectralFlatness: 0,
            averageRMS: 0, peakAmplitude: 0, introRegion: nil, outroRegion: nil,
            vocalOnsetTimestamps: [], vocalOffsetTimestamps: []
        )
    }
}
