//
//  AudioHelpers.swift
//  Cella
//
//  Audio utility functions using Accelerate for DSP operations.
//  Optimized: single FFT pass for spectral features, reusable FFTSetup.
//

import AVFoundation
import Accelerate

enum AudioHelpers {
    enum FadeType {
        case fadeIn
        case fadeOut
    }

    // MARK: - File I/O

    static func readAudio(url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url)
    }

    static func writeAudio(url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        try AVAudioFile(forWriting: url, settings: format.settings)
    }

    // MARK: - Normalization

    static func normalize(buffer: inout AVAudioPCMBuffer, level: Float = 1.0) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            var peak: Float = 0
            vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frameLength))
            guard peak > 0 else { continue }
            let scale = level / peak
            var scaleVec = scale
            vDSP_vsmul(samples, 1, &scaleVec, samples, 1, vDSP_Length(frameLength))
        }
    }

    // MARK: - Equal-Power Fade

    static func equalPowerFade(buffer: inout AVAudioPCMBuffer, type: FadeType, duration: Double) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        let fadeFrames = Int(duration * sampleRate)
        let fadeLength = min(fadeFrames, frameLength)
        guard fadeLength > 0 else { return }

        let channelCount = Int(buffer.format.channelCount)

        for channel in 0..<channelCount {
            let samples = channelData[channel]

            for i in 0..<fadeLength {
                let t = Float(i) / Float(fadeLength - 1)
                let s = t * t * t * (6.0 * t * t - 15.0 * t + 10.0)
                let gain: Float
                switch type {
                case .fadeIn:
                    gain = cos((1.0 - s) * .pi / 2.0)
                case .fadeOut:
                    gain = cos(s * .pi / 2.0)
                }
                samples[i] = samples[i] * gain
            }

            if type == .fadeOut, fadeLength < frameLength {
                for i in fadeLength..<frameLength {
                    samples[i] = 0
                }
            }
        }
    }

    // MARK: - Soft Limiter

    static func softLimit(buffer: inout AVAudioPCMBuffer, threshold: Float = 0.9) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            let invThreshold: Float = 1.0 / threshold
            for i in 0..<frameLength {
                let scaled = samples[i] * invThreshold
                samples[i] = Float(tanh(Double(scaled))) * threshold
            }
        }
    }

    // MARK: - Soft Compression

    static func softCompression(buffer: inout AVAudioPCMBuffer, threshold: Float = 0.85, ratio: Float = 3.0) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let kneeWidth: Float = 0.1
        let kneeStart = threshold - kneeWidth

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for i in 0..<frameLength {
                let absSample = abs(samples[i])
                if absSample <= kneeStart { continue }

                var compressedAbs: Float
                if absSample <= threshold {
                    let normalized = (absSample - kneeStart) / kneeWidth
                    let localRatio = 1.0 + (ratio - 1.0) * normalized * 0.5
                    compressedAbs = kneeStart + (absSample - kneeStart) / localRatio
                } else {
                    compressedAbs = threshold + (absSample - threshold) / ratio
                }
                samples[i] = samples[i] >= 0 ? compressedAbs : -compressedAbs
            }
        }
    }

    // MARK: - Gain Limiting

    static func gainLimit(
        buffer: inout AVAudioPCMBuffer,
        targetLevel: Float = 1.0,
        maxBoostDB: Float = 6.0,
        maxReductionDB: Float = -10.0
    ) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var overallRMS: Float = 0
        for channel in 0..<channelCount {
            var rms: Float = 0
            vDSP_rmsqv(channelData[channel], 1, &rms, vDSP_Length(frameLength))
            overallRMS = max(overallRMS, rms)
        }

        guard overallRMS > 0 else { return }
        let desiredGainDB = 20.0 * log10(targetLevel / overallRMS)
        let clampedGainDB = max(maxReductionDB, min(maxBoostDB, desiredGainDB))
        let finalGain = pow(10.0, clampedGainDB / 20.0)

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            var gain = finalGain
            vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(frameLength))
        }
    }

    // MARK: - Final Mix Normalization

    static func finalMixNormalization(
        buffer: inout AVAudioPCMBuffer,
        targetPeak: Float = 0.95,
        gainRange: (min: Float, max: Float) = (0.8, 1.2)
    ) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var peak: Float = 0
        for channel in 0..<channelCount {
            var channelPeak: Float = 0
            vDSP_maxmgv(channelData[channel], 1, &channelPeak, vDSP_Length(frameLength))
            peak = max(peak, channelPeak)
        }

        guard peak > 0 else { return }
        let clampedGain = max(gainRange.min, min(gainRange.max, targetPeak / peak))

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            var gain = clampedGain
            vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(frameLength))
        }

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            var low: Float = -1.0
            var high: Float = 1.0
            vDSP_vclip(samples, 1, &low, &high, samples, 1, vDSP_Length(frameLength))
        }
    }

    // MARK: - Spectral Analysis (Windowed FFT)

    struct SpectralFeatures {
        var centroid: Float = 0
        var rolloff: Float = 0
        var bandwidth: Float = 0
        var flatness: Float = 0
    }

    /// Computes spectral features by averaging valid power-of-two FFT windows across the track.
    static func computeSpectralFeatures(buffer: AVAudioPCMBuffer) -> SpectralFeatures {
        guard let channelData = buffer.floatChannelData else { return SpectralFeatures() }
        let frameLength = Int(buffer.frameLength)
        guard frameLength >= 2048 else { return SpectralFeatures() }

        let sampleRate = Float(buffer.format.sampleRate)
        let fftSize = min(8192, largestPowerOfTwo(atMost: frameLength))
        guard fftSize >= 2048 else { return SpectralFeatures() }

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return SpectralFeatures() }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let mono = channelData[0]
        let windowCount = min(8, max(1, frameLength / fftSize))
        let maxStart = frameLength - fftSize
        var totals = SpectralFeatures()

        for index in 0..<windowCount {
            let start: Int
            if windowCount == 1 {
                start = maxStart / 2
            } else {
                start = Int(Double(maxStart) * Double(index) / Double(windowCount - 1))
            }

            let features = computeSpectralFeatures(
                data: mono + start,
                frameCount: fftSize,
                sampleRate: sampleRate,
                fftSetup: fftSetup,
                log2n: log2n
            )
            totals.centroid += features.centroid
            totals.rolloff += features.rolloff
            totals.bandwidth += features.bandwidth
            totals.flatness += features.flatness
        }

        let count = Float(windowCount)
        return SpectralFeatures(
            centroid: totals.centroid / count,
            rolloff: totals.rolloff / count,
            bandwidth: totals.bandwidth / count,
            flatness: totals.flatness / count
        )
    }

    private static func computeSpectralFeatures(
        data: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Float,
        fftSetup: OpaquePointer,
        log2n: vDSP_Length
    ) -> SpectralFeatures {
        let halfN = frameCount / 2

        // Apply Hanning window
        var window = [Float](repeating: 0, count: frameCount)
        vDSP_hann_window(&window, vDSP_Length(frameCount), Int32(vDSP_HANN_NORM))

        var windowed = [Float](repeating: 0, count: frameCount)
        vDSP_vmul(data, 1, window, 1, &windowed, 1, vDSP_Length(frameCount))

        // Single forward FFT
        var realPart = [Float](repeating: 0, count: halfN)
        var imagPart = [Float](repeating: 0, count: halfN)
        var magnitudes = [Float](repeating: 0, count: halfN)

        realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress,
                      let imagBase = imagPtr.baseAddress else { return }

                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)

                windowed.withUnsafeBytes { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfN))
                    }
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfN))
            }
        }

        // --- Centroid ---
        var weightedSum: Float = 0
        var magnitudeSum: Float = 0
        for k in 0..<halfN {
            let freq = Float(k) * sampleRate / Float(frameCount)
            weightedSum += magnitudes[k] * freq
            magnitudeSum += magnitudes[k]
        }
        let centroid = magnitudeSum > 0 ? weightedSum / magnitudeSum : 0

        // --- Rolloff (85%) ---
        let threshold85 = magnitudeSum * 0.85
        var cumEnergy: Float = 0
        var rolloff = sampleRate / 2
        for k in 0..<halfN {
            cumEnergy += magnitudes[k]
            if cumEnergy >= threshold85 {
                rolloff = Float(k) * sampleRate / Float(frameCount)
                break
            }
        }

        // --- Bandwidth ---
        var weightedVariance: Float = 0
        for k in 0..<halfN {
            let freq = Float(k) * sampleRate / Float(frameCount)
            let diff = freq - centroid
            weightedVariance += magnitudes[k] * diff * diff
        }
        let bandwidth = magnitudeSum > 0 ? sqrt(weightedVariance / magnitudeSum) : 0

        // --- Flatness ---
        let arithmeticMean = magnitudeSum / Float(halfN)
        var logSum: Float = 0
        var validCount: Float = 0
        for m in magnitudes where m > 1e-10 {
            logSum += log(m)
            validCount += 1
        }
        let flatness: Float
        if validCount > 0, arithmeticMean > 1e-10 {
            flatness = exp(logSum / validCount) / arithmeticMean
        } else {
            flatness = 0
        }

        return SpectralFeatures(centroid: centroid, rolloff: rolloff, bandwidth: bandwidth, flatness: flatness)
    }

    /// Computes spectral centroid for a window using a pre-created FFTSetup.
    static func computeWindowSpectralCentroid(
        data: UnsafePointer<Float>,
        frameCount: Int,
        sampleRate: Float,
        fftSetup: OpaquePointer,
        log2n: vDSP_Length
    ) -> Float {
        let maxFFTSize = 1 << Int(log2n)
        let fftSize = min(largestPowerOfTwo(atMost: frameCount), maxFFTSize)
        guard fftSize >= 2048 else { return 0 }

        let fftLog2n = vDSP_Length(log2(Float(fftSize)))
        return computeSpectralFeatures(
            data: data,
            frameCount: fftSize,
            sampleRate: sampleRate,
            fftSetup: fftSetup,
            log2n: fftLog2n
        ).centroid
    }

    private static func largestPowerOfTwo(atMost value: Int) -> Int {
        guard value > 1 else { return value }

        var power = 1
        while power <= value / 2 {
            power *= 2
        }
        return power
    }

    // MARK: - RMS Energy Profile

    /// Computes RMS energy profile using sliding windows. Vectorized mono mixdown.
    static func getRMSProfile(buffer: AVAudioPCMBuffer, windowSize: Int = 4096) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength >= windowSize else { return [] }

        // Vectorized mono mixdown
        var mono = [Float](repeating: 0, count: frameLength)
        if channelCount >= 2 {
            var scale: Float = 0.5
            vDSP_vadd(channelData[0], 1, channelData[1], 1, &mono, 1, vDSP_Length(frameLength))
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(frameLength))
        } else {
            for i in 0..<frameLength {
                mono[i] = channelData[0][i]
            }
        }

        let hopSize = windowSize / 2
        var rmsValues = [Float]()
        var offset = 0

        while offset + windowSize <= frameLength {
            var rms: Float = 0
            mono.withUnsafeBufferPointer { ptr in
                vDSP_rmsqv(ptr.baseAddress! + offset, 1, &rms, vDSP_Length(windowSize))
            }
            rmsValues.append(rms)
            offset += hopSize
        }

        return rmsValues
    }

    // MARK: - Beat Detection (onset-based, no pitch shift)

    /// Detects actual beat positions from positive spectral flux onsets, phase-locked
    /// to the strongest onset near the start. Tempo is taken from external BPM.
    /// Returns (beat timestamps, time of first beat, relative score).
    static func detectBeats(buffer: AVAudioPCMBuffer, bpm: Double) -> (beats: [Double], firstBeat: Double, score: Float) {
        guard let channelData = buffer.floatChannelData, bpm > 0 else { return ([], 0, 0) }
        let frameLength = Int(buffer.frameLength)
        guard frameLength >= 2048 else { return ([], 0, 0) }
        let sampleRate = Double(buffer.format.sampleRate)
        let mono = channelData[0]

        let windowSize = 2048
        let hop = 1024
        let halfN = windowSize / 2
        let log2n = vDSP_Length(log2(Float(windowSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], 0, 0) }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        var envelope = [Float]()
        var prevMag = [Float](repeating: 0, count: halfN)
        var position = 0
        while position + windowSize <= frameLength {
            var windowed = [Float](repeating: 0, count: windowSize)
            for i in 0..<windowSize { windowed[i] = mono[position + i] * window[i] }

            var realPart = [Float](repeating: 0, count: halfN)
            var imagPart = [Float](repeating: 0, count: halfN)
            var split = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
            windowed.withUnsafeBytes { ptr in
                ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) { cp in
                    vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(halfN))
                }
            }
            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

            var mag = [Float](repeating: 0, count: halfN)
            vDSP_zvmags(&split, 1, &mag, 1, vDSP_Length(halfN))

            // Positive spectral flux only.
            var flux: Float = 0
            for k in 0..<halfN {
                let d = mag[k] - prevMag[k]
                if d > 0 { flux += d }
                prevMag[k] = mag[k]
            }
            envelope.append(flux)
            position += hop
        }
        guard envelope.count > 4 else { return ([], 0, 0) }

        // Normalize envelope.
        var maxF: Float = 0
        vDSP_maxmgv(envelope, 1, &maxF, vDSP_Length(envelope.count))
        if maxF > 0 {
            var inv = 1.0 / maxF
            vDSP_vsmul(envelope, 1, &inv, &envelope, 1, vDSP_Length(envelope.count))
        }

        let hopTime = Double(hop) / sampleRate
        let beatPeriod = Double(60.0 / bpm) / hopTime

        // Phase search: find start offset (within first ~2 beats) that best fits the grid.
        let searchRange = max(1, Int(beatPeriod * 2))
        var bestOffset = 0
        var bestScore: Float = -1
        let step = max(1, Int(beatPeriod))
        for s in 0..<searchRange {
            var score: Float = 0
            var k = s
            while k < envelope.count {
                score += envelope[k]
                k += step
            }
            if score > bestScore {
                bestScore = score
                bestOffset = s
            }
        }

        let firstBeat = Double(bestOffset) * hopTime
        let beatInterval = 60.0 / bpm
        var beats = [Double]()
        var t = firstBeat
        let total = Double(frameLength) / sampleRate
        while t < total {
            beats.append(t)
            t += beatInterval
        }
        return (beats, firstBeat, bestScore)
    }

    // MARK: - Peak Amplitude

    static func peakAmplitude(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        var peak: Float = 0
        for ch in 0..<channelCount {
            var channelPeak: Float = 0
            vDSP_maxmgv(channelData[ch], 1, &channelPeak, vDSP_Length(frameLength))
            peak = max(peak, channelPeak)
        }
        return peak
    }

    // MARK: - Vocal Onset/Offset Detection

    static func detectVocalBoundaries(
        buffer: AVAudioPCMBuffer,
        windowSize: Int = 4096,
        hopSize: Int = 4096,
        onsetThreshold: Float = 0.03,
        offsetThreshold: Float = 0.015,
        minGapDuration: Double = 0.3
    ) -> (onsets: [Double], offsets: [Double]) {
        guard let channelData = buffer.floatChannelData else { return ([], []) }
        let frameLength = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        let channelCount = Int(buffer.format.channelCount)

        var rmsValues = [Float]()
        var offset = 0
        while offset + windowSize <= frameLength {
            var rms: Float = 0
            for ch in 0..<channelCount {
                var chRms: Float = 0
                vDSP_rmsqv(channelData[ch] + offset, 1, &chRms, vDSP_Length(windowSize))
                rms = max(rms, chRms)
            }
            rmsValues.append(rms)
            offset += hopSize
        }

        guard rmsValues.count >= 3 else { return ([], []) }

        var onsets = [Double]()
        var offsets = [Double]()
        let windowDuration = Double(hopSize) / sampleRate

        for i in 1..<(rmsValues.count - 1) {
            let prev = rmsValues[i - 1]
            let curr = rmsValues[i]

            if prev < onsetThreshold && curr >= onsetThreshold {
                let time = Double(i) * windowDuration
                if onsets.isEmpty || (time - onsets.last!) >= minGapDuration {
                    onsets.append(time)
                }
            }

            if prev >= offsetThreshold && curr < offsetThreshold {
                let time = Double(i) * windowDuration
                if offsets.isEmpty || (time - offsets.last!) >= minGapDuration {
                    offsets.append(time)
                }
            }
        }

        return (onsets, offsets)
    }

    // MARK: - Buffer Utilities

    static func mixBuffers(
        _ bufferA: AVAudioPCMBuffer,
        _ bufferB: AVAudioPCMBuffer,
        gainA: Float = 1.0,
        gainB: Float = 1.0
    ) -> AVAudioPCMBuffer? {
        let frameLength = min(bufferA.frameLength, bufferB.frameLength)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: bufferA.format.sampleRate,
            channels: bufferA.format.channelCount,
            interleaved: false
        ) else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameLength) else {
            return nil
        }
        outputBuffer.frameLength = frameLength

        guard let dataA = bufferA.floatChannelData,
              let dataB = bufferB.floatChannelData,
              let dataOut = outputBuffer.floatChannelData else { return nil }

        let channelCount = Int(outputFormat.channelCount)
        let count = vDSP_Length(frameLength)

        for ch in 0..<channelCount {
            var scaledA = [Float](repeating: 0, count: Int(frameLength))
            var scaledB = [Float](repeating: 0, count: Int(frameLength))
            var gA = gainA, gB = gainB
            vDSP_vsmul(dataA[ch], 1, &gA, &scaledA, 1, count)
            vDSP_vsmul(dataB[ch], 1, &gB, &scaledB, 1, count)
            vDSP_vadd(scaledA, 1, scaledB, 1, dataOut[ch], 1, count)
        }

        return outputBuffer
    }

    static func extractBuffer(
        _ source: AVAudioPCMBuffer,
        from startFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard let channelData = source.floatChannelData else { return nil }
        guard startFrame >= 0,
              startFrame + AVAudioFramePosition(frameCount) <= AVAudioFramePosition(source.frameLength) else {
            return nil
        }

        guard let output = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frameCount) else { return nil }
        guard let outData = output.floatChannelData else { return nil }

        let channelCount = Int(source.format.channelCount)
        let start = Int(startFrame)

        for ch in 0..<channelCount {
            outData[ch].update(from: channelData[ch] + start, count: Int(frameCount))
        }

        output.frameLength = frameCount
        return output
    }

    // MARK: - Silence & Concatenation

    static func createSilence(frames: AVAudioFramePosition, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard frames > 0 else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channelData = buffer.floatChannelData {
            for ch in 0..<Int(format.channelCount) {
                channelData[ch].update(repeating: 0, count: Int(frames))
            }
        }
        return buffer
    }

    static func concatenateBuffers(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = buffers.first else { return nil }
        let format = first.format
        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(totalFrames)) else { return nil }
        guard let outData = output.floatChannelData else { return nil }
        let channelCount = Int(format.channelCount)
        var offset = 0
        for buf in buffers {
            if let inData = buf.floatChannelData {
                let len = Int(buf.frameLength)
                for ch in 0..<channelCount {
                    outData[ch].advanced(by: offset).update(from: inData[ch], count: len)
                }
            }
            offset += Int(buf.frameLength)
        }
        output.frameLength = AVAudioFrameCount(totalFrames)
        return output
    }
}
