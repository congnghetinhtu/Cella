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
    // MARK: - File I/O

    static func readAudio(url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url)
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

    // MARK: - Beat Detection (log-spectral-flux + autocorrelation confidence)

    /// Detects beat positions from log-compressed, bass-weighted positive spectral flux.
    /// Computes `confidence` (0.0 = free-time/ambient, 1.0 = locked percussive beat) via
    /// normalized autocorrelation at 1×/2× beat period vs off-beat lags, which is robust
    /// on dense mastered Pop/EDM tracks and immune to single cymbal spikes or phase drift.
    static func detectBeats(
        buffer: AVAudioPCMBuffer,
        bpm: Double
    ) -> (beats: [Double], firstBeat: Double, confidence: Float, effectiveBPM: Double) {
        guard let channelData = buffer.floatChannelData, bpm > 0 else { return ([], 0, 0, bpm) }
        let frameLength = Int(buffer.frameLength)
        guard frameLength >= 2048 else { return ([], 0, 0, bpm) }
        let sampleRate = Double(buffer.format.sampleRate)
        let mono = channelData[0]

        let windowSize = 2048
        let hop = 512
        let halfN = windowSize / 2
        let log2n = vDSP_Length(log2(Float(windowSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return ([], 0, 0, bpm) }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let binHz = Float(sampleRate) / Float(windowSize)
        let kickLo = max(1, Int(40.0 / binHz))
        let kickHi = min(halfN - 1, Int(220.0 / binHz))
        let snareLo = max(1, Int(1000.0 / binHz))
        let snareHi = min(halfN - 1, Int(6000.0 / binHz))

        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        var envelope = [Float]()
        envelope.reserveCapacity(frameLength / hop)
        var prevLogMag = [Float](repeating: 0, count: halfN)
        var isFirstFrame = true
        var position = 0

        while position + windowSize <= frameLength {
            var windowed = [Float](repeating: 0, count: windowSize)
            vDSP_vmul(mono + position, 1, window, 1, &windowed, 1, vDSP_Length(windowSize))

            var realPart = [Float](repeating: 0, count: halfN)
            var imagPart = [Float](repeating: 0, count: halfN)
            var magSq = [Float](repeating: 0, count: halfN)
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
                    vDSP_zvmags(&split, 1, &magSq, 1, vDSP_Length(halfN))
                }
            }

            // Log-compressed amplitude spectrum makes kick/snare onsets stand out
            // cleanly even in loudly mastered Pop/V-Pop/EDM mixes.
            var flux: Float = 0
            if isFirstFrame {
                for k in 0..<halfN {
                    prevLogMag[k] = log1p(50.0 * sqrt(max(0, magSq[k])))
                }
                envelope.append(0)
                isFirstFrame = false
            } else {
                for k in 1..<halfN {
                    let cur = log1p(50.0 * sqrt(max(0, magSq[k])))
                    let d = cur - prevLogMag[k]
                    if d > 0 {
                        let weight: Float
                        if k >= kickLo && k <= kickHi {
                            weight = 2.0
                        } else if k >= snareLo && k <= snareHi {
                            weight = 1.2
                        } else {
                            weight = 0.5
                        }
                        flux += d * weight
                    }
                    prevLogMag[k] = cur
                }
                envelope.append(flux)
            }
            position += hop
        }

        let envCount = envelope.count
        guard envCount > 16 else { return ([], 0, 0, bpm) }

        // Adaptive local mean subtraction (~0.35s window) removes continuous vocal/synth floor.
        let hopTime = Double(hop) / sampleRate
        let localHalf = max(2, Int((0.18 / hopTime).rounded()))
        var onset = [Float](repeating: 0, count: envCount)
        var runningSum: Float = 0
        for i in 0..<min(localHalf, envCount) { runningSum += envelope[i] }
        for i in 0..<envCount {
            if i + localHalf < envCount { runningSum += envelope[i + localHalf] }
            if i - localHalf - 1 >= 0 { runningSum -= envelope[i - localHalf - 1] }
            let winLen = Float(min(envCount - 1, i + localHalf) - max(0, i - localHalf) + 1)
            let localMean = runningSum / max(1, winLen)
            onset[i] = max(0, envelope[i] - localMean * 1.05)
        }

        // Normalize by 95th percentile (immune to single outlier spikes).
        // Real percussive music has p95 log-flux >> 20; steady pads/sines sit below 8.
        let sorted = onset.sorted()
        let p95 = sorted[Int(Double(envCount - 1) * 0.95)]
        guard p95 > 8.0 else { return ([], 0, 0, bpm) }
        let invP95 = 1.0 / p95
        for i in 0..<envCount {
            onset[i] = min(2.0, onset[i] * invP95)
        }

        let effectiveBpm = bpm
        let beatPeriod = (60.0 / effectiveBpm) / hopTime
        guard beatPeriod >= 2.0 else { return ([], 0, 0, effectiveBpm) }

        // Autocorrelation-based beatConfidence: compare onset periodicity at
        // 1× and 2× beatPeriod against off-beat lags (0.35× and 0.65× beatPeriod).
        func autocorr(atLag lag: Int) -> Float {
            guard lag > 0, lag < envCount - 4 else { return 0 }
            var sum: Float = 0
            let n = envCount - lag
            vDSP_dotpr(onset, 1, Array(onset[lag...]), 1, &sum, vDSP_Length(n))
            return sum / Float(n)
        }

        let lag1 = Int(beatPeriod.rounded())
        let lag2 = Int((beatPeriod * 2.0).rounded())
        let off1 = max(1, Int((beatPeriod * 0.35).rounded()))
        let off2 = max(1, Int((beatPeriod * 0.65).rounded()))

        // Allow ±1 frame tolerance around the beat lag for slight tempo imprecision.
        let rBeat1 = max(autocorr(atLag: lag1), max(autocorr(atLag: max(1, lag1 - 1)), autocorr(atLag: lag1 + 1)))
        let rBeat2 = max(autocorr(atLag: lag2), max(autocorr(atLag: max(1, lag2 - 1)), autocorr(atLag: lag2 + 1)))
        let rOnBeat = (rBeat1 * 0.65 + rBeat2 * 0.35)
        let rOffBeat = max(1e-5, (autocorr(atLag: off1) + autocorr(atLag: off2)) * 0.5)
        let rZero = max(1e-5, autocorr(atLag: 0))

        // Contrast ratio (on-beat vs off-beat) + absolute periodicity strength.
        let contrast = rOnBeat / rOffBeat
        let normStrength = rOnBeat / rZero
        let contrastScore = min(1.0, max(0.0, (contrast - 1.08) / 1.15))
        let strengthScore = min(1.0, max(0.0, normStrength / 0.25))
        let confidence = min(1.0, max(0.0, contrastScore * 0.7 + strengthScore * 0.3))

        // Phase search on a middle body segment (~60s) so free-time intros don't
        // misalign the downbeat and long tracks don't drift out of phase.
        let bodyStart = envCount > 2000 ? envCount / 5 : 0
        let bodyEnd = min(envCount, bodyStart + Int(60.0 / hopTime))
        let searchRange = max(1, Int(beatPeriod.rounded()))
        var bestOffset = 0
        var bestScore: Float = -1

        for s in 0..<searchRange {
            var score: Float = 0
            var beatNum = 0
            while true {
                let idx = bodyStart + Int((Double(s) + Double(beatNum) * beatPeriod).rounded())
                guard idx < bodyEnd else { break }
                var local = onset[idx]
                if idx > 0 { local += 0.4 * onset[idx - 1] }
                if idx + 1 < envCount { local += 0.4 * onset[idx + 1] }
                score += local
                beatNum += 1
            }
            if score > bestScore {
                bestScore = score
                bestOffset = s
            }
        }

        // Project the locked phase back to the first beat >= 0.
        let lockedTime = Double(bodyStart + bestOffset) * hopTime
        let beatInterval = 60.0 / effectiveBpm
        let firstBeat = lockedTime.truncatingRemainder(dividingBy: beatInterval)
        var beats = [Double]()
        var t = firstBeat
        let total = Double(frameLength) / sampleRate
        while t < total {
            beats.append(t)
            t += beatInterval
        }
        return (beats, firstBeat, confidence, effectiveBpm)
    }

    // MARK: - Silence Boundary Detection

    /// Measures leading silence (seconds from start before audio exceeds -50 dBFS)
    /// and trailing silence onset (timestamp where audio stays below -45 dBFS to the end).
    static func detectSilenceBounds(
        buffer: AVAudioPCMBuffer,
        leadingThreshold: Float = 0.00316,   // ~ -50 dBFS
        trailingThreshold: Float = 0.00562   // ~ -45 dBFS
    ) -> (leading: Double, trailing: Double) {
        guard let channelData = buffer.floatChannelData else { return (0, 0) }
        let frameLength = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard frameLength > 0, sampleRate > 0 else { return (0, 0) }

        let totalDuration = Double(frameLength) / sampleRate
        let windowSize = max(256, Int(sampleRate * 0.05)) // 50ms windows
        let mono = channelData[0]
        let windowCount = frameLength / windowSize
        guard windowCount > 0 else { return (0, totalDuration) }

        var rmsPerWindow = [Float](repeating: 0, count: windowCount)
        for w in 0..<windowCount {
            var rms: Float = 0
            vDSP_rmsqv(mono + (w * windowSize), 1, &rms, vDSP_Length(windowSize))
            rmsPerWindow[w] = rms
        }

        let windowSec = Double(windowSize) / sampleRate

        var leading = 0.0
        for w in 0..<windowCount {
            if rmsPerWindow[w] >= leadingThreshold {
                leading = Double(w) * windowSec
                break
            }
        }

        var trailing = totalDuration
        for w in stride(from: windowCount - 1, through: 0, by: -1) {
            if rmsPerWindow[w] >= trailingThreshold {
                trailing = min(totalDuration, Double(w + 1) * windowSec)
                break
            }
        }

        // Guard against completely silent/unusual files
        if trailing <= leading {
            return (0, totalDuration)
        }
        return (leading, trailing)
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

    /// Detects vocal phrase boundaries directly from the spectral vocalActivity
    /// envelope using moving-average smoothing + hysteresis thresholds.
    /// Avoids false triggers from percussive drums or synth intros.
    static func detectVocalBoundaries(
        vocalActivity: [Float],
        duration: Double,
        onsetThreshold: Float = 0.42,
        offsetThreshold: Float = 0.22,
        minGapDuration: Double = 0.5
    ) -> (onsets: [Double], offsets: [Double]) {
        guard vocalActivity.count >= 3, duration > 0 else { return ([], []) }

        // 3-window moving average smooth to reject single-frame transient spikes.
        var smoothed = [Float](repeating: 0, count: vocalActivity.count)
        for i in 0..<vocalActivity.count {
            let lo = max(0, i - 1)
            let hi = min(vocalActivity.count - 1, i + 1)
            var sum: Float = 0
            for j in lo...hi { sum += vocalActivity[j] }
            smoothed[i] = sum / Float(hi - lo + 1)
        }

        let windowDuration = duration / Double(smoothed.count)
        var onsets = [Double]()
        var offsets = [Double]()
        var inVocal = false

        for i in 0..<smoothed.count {
            let val = smoothed[i]
            let time = Double(i) * windowDuration

            if !inVocal && val >= onsetThreshold {
                if onsets.isEmpty || (time - onsets.last!) >= minGapDuration {
                    onsets.append(time)
                }
                inVocal = true
            } else if inVocal && val <= offsetThreshold {
                if offsets.isEmpty || (time - offsets.last!) >= minGapDuration {
                    offsets.append(time)
                }
                inVocal = false
            }
        }

        if inVocal {
            offsets.append(duration)
        }

        return (onsets, offsets)
    }

    // MARK: - Buffer Utilities

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
