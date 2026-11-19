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

        // Shared FFT setup for vocal + bass band extraction
        let fftWindow = 4096
        let log2n = vDSP_Length(log2(Float(fftWindow)))
        let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))

        // Compute all buffer-based features in one pass
        let energyProfile = AudioHelpers.getRMSProfile(buffer: buffer, windowSize: 8192)
        let silenceBounds = AudioHelpers.detectSilenceBounds(buffer: buffer)
        let structureSections = detectSections(
            energyProfile: energyProfile,
            duration: audioFile.duration,
            leadingSilence: silenceBounds.leading,
            trailingSilence: silenceBounds.trailing
        )
        let introOutro = detectIntroOutro(structureSections: structureSections)
        let spectral = AudioHelpers.computeSpectralFeatures(buffer: buffer)
        let avgRMS = averageEnergy(energyProfile)
        let peakAmp = AudioHelpers.peakAmplitude(buffer: buffer)
        let beatInfo = AudioHelpers.detectBeats(buffer: buffer, bpm: bpm ?? 0)
        let beatTimestamps = beatInfo.beats
        let beatConfidence = beatInfo.confidence
        let effectiveBPM = beatInfo.effectiveBPM > 0 ? beatInfo.effectiveBPM : nil

        // Vocal + Bass band extraction in a single shared FFT pass
        let hasVocals: Bool
        let vocalActivity: [Float]
        let bassEnergyProfile: [Float]
        let vocalBoundaries: (onsets: [Double], offsets: [Double])

        if let setup = fftSetup {
            let bands = extractBandProfiles(buffer: buffer, fftSetup: setup, log2n: log2n)
            vocalActivity = bands.vocalActivity
            bassEnergyProfile = bands.bassEnergy
            vocalBoundaries = AudioHelpers.detectVocalBoundaries(
                vocalActivity: vocalActivity,
                duration: audioFile.duration
            )
            // Confirm vocal presence if sustained vocal activity appears in multiple windows
            let activeWindows = vocalActivity.filter { $0 >= 0.42 }.count
            hasVocals = activeWindows >= 3 || detectVocals(buffer: buffer, fftSetup: setup, log2n: log2n)
            vDSP_destroy_fftsetup(setup)
        } else {
            hasVocals = false
            vocalActivity = []
            bassEnergyProfile = []
            vocalBoundaries = ([], [])
        }

        // Build true 4/4 bar grid aligned to the strongest downbeat phase (0..3)
        // measured by bass + RMS accents across the track body.
        let downbeatPhase = detectDownbeatPhase(
            beatTimestamps: beatTimestamps,
            energyProfile: energyProfile,
            bassEnergyProfile: bassEnergyProfile,
            duration: audioFile.duration
        )
        let barTimestamps = stride(from: downbeatPhase, to: beatTimestamps.count, by: 4).map { beatTimestamps[$0] }

        let result = TrackAnalysis(
            schemaVersion: TrackAnalysis.currentSchemaVersion,
            bpm: effectiveBPM,
            beatTimestamps: beatTimestamps,
            barTimestamps: barTimestamps,
            beatConfidence: beatConfidence,
            keySignature: keySignature,
            loudnessIntegrated: loudnessDesc?.loudnessIntegrated,
            structureSections: structureSections,
            energyProfile: energyProfile,
            bassEnergyProfile: bassEnergyProfile,
            hasVocals: hasVocals,
            vocalActivity: vocalActivity,
            duration: audioFile.duration,
            leadingSilence: silenceBounds.leading,
            trailingSilence: silenceBounds.trailing,
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

    /// Bounds any single track: a hung file must never wedge the whole queue.
    /// On timeout the track plays unanalyzed (neutral mood, default blend)
    /// and progress keeps moving.
    static let perTrackTimeout: Double = 240

    private func analyzeWithTimeout(url: URL) async throws -> TrackAnalysis {
        try await withThrowingTaskGroup(of: TrackAnalysis.self) { group in
            group.addTask { try await self.analyze(url: url) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.perTrackTimeout * 1_000_000_000))
                throw CancellationError()
            }
            guard let result = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            return result
        }
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
                            let analysis = try await self.analyzeWithTimeout(url: asset.url)
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

    // MARK: - Structure Detection (relative-energy & position aware)

    private func detectSections(
        energyProfile: [Float],
        duration: Double,
        leadingSilence: Double,
        trailingSilence: Double
    ) -> [TrackAnalysis.StructureSection] {
        guard energyProfile.count >= 6, duration > 0 else { return [] }

        let count = energyProfile.count
        let timePerSample = duration / Double(count)

        // Smooth energy profile with a ~4s moving average so transient beats don't split sections.
        let smoothHalf = max(1, Int((2.0 / max(timePerSample, 0.05)).rounded()))
        var smoothed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let lo = max(0, i - smoothHalf)
            let hi = min(count - 1, i + smoothHalf)
            var sum: Float = 0
            for j in lo...hi { sum += energyProfile[j] }
            smoothed[i] = sum / Float(hi - lo + 1)
        }

        // Compute relative percentiles across audible samples so quiet ballads and loud EDM both classify accurately.
        let audible = smoothed.filter { $0 > 0.005 }.sorted()
        guard !audible.isEmpty else { return [] }
        let p25 = audible[Int(Double(audible.count - 1) * 0.25)]
        let p45 = audible[Int(Double(audible.count - 1) * 0.45)]
        let p70 = audible[Int(Double(audible.count - 1) * 0.70)]
        let energySpan = max(0.02, audible.last! - audible.first!)
        let splitThreshold = max(0.04, energySpan * 0.22)
        let minSectionSamples = max(2, Int((8.0 / max(timePerSample, 0.05)).rounded()))

        var boundaries = [0]
        var anchorEnergy = smoothed[0]
        for i in 1..<count {
            if (i - boundaries.last!) >= minSectionSamples && abs(smoothed[i] - anchorEnergy) >= splitThreshold {
                boundaries.append(i)
                anchorEnergy = smoothed[i]
            }
        }
        boundaries.append(count)

        let effectiveEnd = max(leadingSilence + 1.0, trailingSilence)
        var sections: [TrackAnalysis.StructureSection] = []
        for idx in 0..<(boundaries.count - 1) {
            let sIdx = boundaries[idx]
            let eIdx = boundaries[idx + 1]
            let startTime = Double(sIdx) * timePerSample
            let endTime = min(duration, Double(eIdx) * timePerSample)
            let avgEnergy = averageRange(smoothed, from: sIdx, to: eIdx)
            let midRatio = ((startTime + endTime) * 0.5) / max(1.0, effectiveEnd)

            let label: String
            if avgEnergy < 0.006 {
                label = "silence"
            } else if idx == 0 && endTime <= duration * 0.30 && avgEnergy < p45 {
                label = "intro"
            } else if startTime >= effectiveEnd * 0.72 && avgEnergy < p45 {
                label = "outro"
            } else if avgEnergy >= p70 {
                label = "chorus"
            } else if midRatio > 0.55 && midRatio < 0.85 && avgEnergy <= p25 {
                label = "bridge"
            } else {
                label = "verse"
            }
            sections.append(TrackAnalysis.StructureSection(startTime: startTime, endTime: endTime, label: label))
        }

        return sections
    }

    private func averageRange(_ array: [Float], from start: Int, to end: Int) -> Float {
        guard start < end, end <= array.count else { return 0 }
        let slice = Array(array[start..<end])
        return slice.reduce(0, +) / Float(slice.count)
    }

    // MARK: - Intro/Outro Detection

    private func detectIntroOutro(
        structureSections: [TrackAnalysis.StructureSection]
    ) -> (intro: (start: Double, end: Double)?, outro: (start: Double, end: Double)?) {
        var intro: (start: Double, end: Double)?
        var outro: (start: Double, end: Double)?

        // Intro: only contiguous leading intro/silence sections from the start of the track.
        for section in structureSections {
            if section.label == "intro" || section.label == "silence" {
                if intro == nil {
                    intro = (start: section.startTime, end: section.endTime)
                } else {
                    intro = (start: intro!.start, end: section.endTime)
                }
            } else {
                break
            }
        }

        // Outro: only contiguous trailing outro/silence sections at the end of the track.
        for section in structureSections.reversed() {
            if section.label == "outro" || section.label == "silence" {
                if outro == nil {
                    outro = (start: section.startTime, end: section.endTime)
                } else {
                    outro = (start: section.startTime, end: outro!.end)
                }
            } else {
                break
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

    /// Single-pass FFT band extractor: computes both per-window `vocalActivity`
    /// (300–3400 Hz vocal-band ratio + spectral centroid + ZCR + RMS) and
    /// `bassEnergy` (20–200 Hz low-end energy normalized to 0.0–1.0).
    private func extractBandProfiles(
        buffer: AVAudioPCMBuffer,
        fftSetup: FFTSetup,
        log2n: vDSP_Length
    ) -> (vocalActivity: [Float], bassEnergy: [Float]) {
        guard let channelData = buffer.floatChannelData else { return ([], []) }
        let frameLength = Int(buffer.frameLength)
        let windowSize = 4096
        let hopSize = 4096
        let halfN = windowSize / 2
        guard frameLength >= windowSize else { return ([], []) }

        let mono = channelData[0]
        let sampleRate = Float(buffer.format.sampleRate)
        let binHz = sampleRate / Float(windowSize)

        let bassLo = max(1, Int(20.0 / binHz))
        let bassHi = min(halfN - 1, Int(200.0 / binHz))
        let vocalLo = max(1, Int(300.0 / binHz))
        let vocalHi = min(halfN - 1, Int(3400.0 / binHz))

        var hann = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&hann, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: windowSize)
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        let capacity = frameLength / hopSize
        var activity = [Float]()
        var bassRaw = [Float]()
        activity.reserveCapacity(capacity)
        bassRaw.reserveCapacity(capacity)

        var position = 0
        while position + windowSize <= frameLength {
            var rms: Float = 0
            vDSP_rmsqv(mono + position, 1, &rms, vDSP_Length(windowSize))

            // Zero-crossing rate
            var crossings: vDSP_Length = 0
            for i in 1..<windowSize {
                if (mono[position + i] >= 0) != (mono[position + i - 1] >= 0) {
                    crossings += 1
                }
            }
            let zcr = Float(crossings) / Float(windowSize)

            // Forward FFT
            vDSP_vmul(mono + position, 1, hann, 1, &windowed, 1, vDSP_Length(windowSize))
            realPart.withUnsafeMutableBufferPointer { realPtr in
                imagPart.withUnsafeMutableBufferPointer { imagPtr in
                    guard let realBase = realPtr.baseAddress,
                          let imagBase = imagPtr.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    windowed.withUnsafeBytes { ptr in
                        ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfN))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(halfN))
                }
            }

            var totalEnergy: Float = 0
            var bassSum: Float = 0
            var vocalSum: Float = 0
            var weightedFreqSum: Float = 0

            for k in 1..<halfN {
                let m = magnitudes[k]
                totalEnergy += m
                weightedFreqSum += m * (Float(k) * binHz)
                if k >= bassLo && k <= bassHi { bassSum += m }
                if k >= vocalLo && k <= vocalHi { vocalSum += m }
            }

            let centroid = totalEnergy > 1e-10 ? (weightedFreqSum / totalEnergy) : 0
            let vocalRatio = totalEnergy > 1e-10 ? (vocalSum / totalEnergy) : 0
            let bassRMS = sqrt(max(0, bassSum)) / Float(windowSize)
            bassRaw.append(bassRMS)

            var score: Float = 0
            if rms > 0.004 {
                let centroidMid: Float = 2200
                let centroidRange: Float = 2400
                let centroidDist = abs(centroid - centroidMid) / centroidRange
                let centroidScore = exp(-centroidDist * centroidDist * 1.1)

                let zcrMid: Float = 0.11
                let zcrRange: Float = 0.10
                let zcrDist = abs(zcr - zcrMid) / zcrRange
                let zcrScore = exp(-zcrDist * zcrDist * 1.1)

                let bandScore = min(1.0, vocalRatio * 1.6)
                let energyScore = min(1.0, rms * 4.0)
                score = (bandScore * 0.40 + centroidScore * 0.25 + zcrScore * 0.20 + energyScore * 0.15)
                if centroid < 200 { score *= 0.45 }
                if centroid > 6500 { score *= 0.65 }
                if zcr < 0.005 { score *= 0.55 }
                if zcr > 0.30 { score *= 0.70 }
            }

            activity.append(min(1.0, max(0.0, score)))
            position += hopSize
        }

        // Normalize bassEnergy to 0.0–1.0 using 95th percentile so a single sub spike doesn't squash the curve.
        var bassEnergy = bassRaw
        if !bassRaw.isEmpty {
            let sorted = bassRaw.sorted()
            let ref = max(1e-5, sorted[Int(Double(sorted.count - 1) * 0.95)])
            bassEnergy = bassRaw.map { min(1.0, $0 / ref) }
        }

        return (activity, bassEnergy)
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

    /// Selects which beat offset (0, 1, 2, or 3) corresponds to beat 1 (the downbeat)
    /// of a 4/4 bar by summing bass + RMS accent strength across the track body.
    private func detectDownbeatPhase(
        beatTimestamps: [Double],
        energyProfile: [Float],
        bassEnergyProfile: [Float],
        duration: Double
    ) -> Int {
        guard beatTimestamps.count >= 8, duration > 0 else { return 0 }
        let startBeat = min(beatTimestamps.count / 5, 32)
        let endBeat = min(beatTimestamps.count, startBeat + 128)
        guard endBeat > startBeat + 4 else { return 0 }

        var phaseScores = [Float](repeating: 0, count: 4)
        for i in startBeat..<endBeat {
            let t = beatTimestamps[i]
            let ratio = max(0, min(0.9999, t / duration))
            var accent: Float = 0
            if !bassEnergyProfile.isEmpty {
                let bIdx = Int(ratio * Double(bassEnergyProfile.count))
                accent += bassEnergyProfile[bIdx] * 0.65
            }
            if !energyProfile.isEmpty {
                let eIdx = Int(ratio * Double(energyProfile.count))
                accent += energyProfile[eIdx] * 0.35
            }
            phaseScores[i % 4] += accent
        }

        var bestPhase = 0
        var bestScore = phaseScores[0]
        for p in 1..<4 where phaseScores[p] > bestScore {
            bestScore = phaseScores[p]
            bestPhase = p
        }
        return bestPhase
    }

    private func emptyAnalysis() -> TrackAnalysis {
        TrackAnalysis(
            schemaVersion: TrackAnalysis.currentSchemaVersion,
            bpm: nil, beatTimestamps: [], barTimestamps: [], beatConfidence: 0, keySignature: nil,
            loudnessIntegrated: nil, structureSections: [], energyProfile: [], bassEnergyProfile: [],
            hasVocals: false, vocalActivity: [], duration: 0, leadingSilence: 0, trailingSilence: 0,
            spectralCentroid: 0, spectralRolloff: 0, spectralBandwidth: 0, spectralFlatness: 0,
            averageRMS: 0, peakAmplitude: 0, introRegion: nil, outroRegion: nil,
            vocalOnsetTimestamps: [], vocalOffsetTimestamps: []
        )
    }
}
