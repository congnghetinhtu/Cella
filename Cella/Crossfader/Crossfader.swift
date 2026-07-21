//
//  Crossfader.swift
//  Cella
//
//  Tempo-aligned, key-corrected, vocal-aware crossfade rendering.
//  Equal-power crossfade with quintic smoothstep + cos/sin curves.
//

import AVFoundation
import Accelerate

/// Determines how vocals are handled during a crossfade transition.
enum VocalTransitionStrategy: Sendable {
    case standard              // Neither track has vocals: standard equal-power crossfade
    case duckIncoming          // Only outgoing has vocals: duck incoming during outgoing vocal phrases
    case duckOutgoing          // Only incoming has vocals: duck outgoing during incoming vocal phrases
    case priorityOutgoing      // Both have vocals, outgoing is stronger: incoming ducks
    case priorityIncoming      // Both have vocals, incoming is stronger: outgoing ducks
}

/// Parameters for a crossfade transition.
struct CrossfadeParams: Sendable {
    /// Duration of the crossfade in seconds.
    let duration: Double

    /// Crossfade point in the outgoing track (seconds from start).
    let crossfadeStart: Double

    /// Vocal transition strategy for this crossfade.
    let vocalStrategy: VocalTransitionStrategy

    /// Transition log entry for this crossfade.
    let transitionLog: TransitionLog

    /// Whether the incoming track's intro should be skipped to align vocals.
    let skipIntro: Bool

    /// Optimal vocal connection point in incoming track (seconds).
    let vocalConnectionPoint: Double

    /// Gain compensation for incoming track (1.0 = no change). Computed from LUFS/RMS difference.
    let incomingGainCompensation: Double

    /// Gain compensation for outgoing track (1.0 = no change).
    let outgoingGainCompensation: Double
}

/// Renders crossfade buffers with tempo alignment, key correction, and vocal ducking.
struct Crossfader {
    let config: AudioConfig

    init(config: AudioConfig = .standard) {
        self.config = config
    }

    // MARK: - Crossfade Parameter Computation

    /// Computes crossfade parameters for a transition between two tracks.
    func computeCrossfadeParams(
        outgoing: TrackAsset,
        incoming: TrackAsset
    ) -> CrossfadeParams {
        let outAnalysis = outgoing.analysis
        let inAnalysis = incoming.analysis

        let crossfadeDuration = Self.computeCrossfadeDuration(
            from: outgoing,
            to: incoming,
            config: config
        )

        // Crossfade starts near the end of the outgoing track
        let crossfadeStart: Double
        if let outDuration = outAnalysis?.duration, outDuration > 0 {
            crossfadeStart = max(0, outDuration - crossfadeDuration)
        } else {
            crossfadeStart = 0
        }

        // Determine vocal transition strategy
        let vocalStrategy = computeVocalStrategy(
            outgoing: outAnalysis,
            incoming: inAnalysis
        )

        // Find optimal vocal connection point (lead-in before first vocal onset)
        let vocalConnectionPoint = findVocalConnectionPoint(
            outgoing: outAnalysis,
            incoming: inAnalysis,
            crossfadeDuration: crossfadeDuration
        )

        // Skip incoming intro to connect vocals seamlessly, but preserve a brief
        // instrumental build-up before the vocal hits so it doesn't start abruptly.
        let skipIntro = vocalConnectionPoint > 0 && (inAnalysis?.hasVocals == true)

        // Compute loudness-matching gain compensation
        let (outGain, inGain) = computeGainCompensation(
            outgoing: outAnalysis,
            incoming: inAnalysis
        )

        // Build transition log
        let transitionLog = TransitionLog(
            fromTrack: outgoing.url,
            toTrack: incoming.url,
            crossfadeDuration: crossfadeDuration,
            bpmAdjusted: false,
            keyCorrected: false,
            vocalDuckingApplied: vocalStrategy != .standard
        )

        return CrossfadeParams(
            duration: crossfadeDuration,
            crossfadeStart: crossfadeStart,
            vocalStrategy: vocalStrategy,
            transitionLog: transitionLog,
            skipIntro: skipIntro,
            vocalConnectionPoint: vocalConnectionPoint,
            incomingGainCompensation: inGain,
            outgoingGainCompensation: outGain
        )
    }

    // MARK: - Gain Compensation

    /// Computes loudness-matching gain for both tracks so perceived volume stays consistent.
    /// Uses LUFS if available, falls back to averageRMS, then peakAmplitude.
    /// Returns (outgoingGain, incomingGain) where 1.0 = no change.
    private func computeGainCompensation(
        outgoing: TrackAnalysis?,
        incoming: TrackAnalysis?
    ) -> (outgoing: Double, incoming: Double) {
        guard let out = outgoing, let incoming = incoming else { return (1.0, 1.0) }

        // Try LUFS first (most accurate for perceived loudness)
        if let outLUFS = out.loudnessIntegrated,
           let inLUFS = incoming.loudnessIntegrated {
            // Both are in dB — compute the difference
            let diffDB = outLUFS - inLUFS
            // The quieter track needs boost, the louder needs attenuation
            // We boost the quieter one rather than attenuate the louder one
            if diffDB > 0 {
                // Outgoing is louder — boost incoming
                let boost = min(config.maxGainBoostDB, Float(diffDB))
                let gain = pow(10.0, boost / 20.0)
                return (1.0, Double(gain))
            } else if diffDB < 0 {
                // Incoming is louder — boost outgoing
                let boost = min(config.maxGainBoostDB, Float(-diffDB))
                let gain = pow(10.0, boost / 20.0)
                return (Double(gain), 1.0)
            }
            return (1.0, 1.0)
        }

        // Fallback to averageRMS
        let outRMS = Double(out.averageRMS)
        let inRMS = Double(incoming.averageRMS)
        guard outRMS > 0.001, inRMS > 0.001 else { return (1.0, 1.0) }

        // Compute ratio: louder track stays at 1.0, quieter gets boosted
        if outRMS > inRMS {
            let ratio = outRMS / inRMS
            let gainDB = 20.0 * log10(ratio)
            let clampedDB = min(Double(config.maxGainBoostDB), gainDB)
            return (1.0, pow(10.0, clampedDB / 20.0))
        } else if inRMS > outRMS {
            let ratio = inRMS / outRMS
            let gainDB = 20.0 * log10(ratio)
            let clampedDB = min(Double(config.maxGainBoostDB), gainDB)
            return (pow(10.0, clampedDB / 20.0), 1.0)
        }

        return (1.0, 1.0)
    }

    // MARK: - Vocal Strategy

    /// Determines the vocal transition strategy based on both tracks' vocal content.
    private func computeVocalStrategy(
        outgoing: TrackAnalysis?,
        incoming: TrackAnalysis?
    ) -> VocalTransitionStrategy {
        let outHasVocals = outgoing?.hasVocals ?? false
        let inHasVocals = incoming?.hasVocals ?? false

        guard outHasVocals || inHasVocals else { return .standard }

        if outHasVocals && !inHasVocals {
            return .duckIncoming
        }

        if !outHasVocals && inHasVocals {
            return .duckOutgoing
        }

        // Both have vocals — determine priority based on vocal activity strength
        let outVocalStrength = averageVocalStrength(outgoing, useEnd: true)
        let inVocalStrength = averageVocalStrength(incoming, useEnd: false)

        // The track with stronger vocals "wins" — the other gets ducked
        if outVocalStrength >= inVocalStrength {
            return .priorityOutgoing
        } else {
            return .priorityIncoming
        }
    }

    /// Computes average vocal activity strength in the crossfade-relevant region.
    private func averageVocalStrength(_ analysis: TrackAnalysis?, useEnd: Bool) -> Float {
        guard let analysis = analysis else { return 0 }
        let activity = analysis.vocalActivity
        guard !activity.isEmpty else { return 0 }

        let sampleCount = min(activity.count, 10)
        let startIdx: Int
        if useEnd {
            startIdx = max(0, activity.count - sampleCount)
        } else {
            startIdx = 0
        }
        let endIdx = min(startIdx + sampleCount, activity.count)
        let slice = Array(activity[startIdx..<endIdx])
        return slice.reduce(0, +) / Float(slice.count)
    }

    // MARK: - Dynamic Crossfade Duration

    private static func computeCrossfadeDuration(
        from: TrackAsset,
        to: TrackAsset,
        config: AudioConfig
    ) -> Double {
        guard let fromAnalysis = from.analysis,
              let toAnalysis = to.analysis else {
            return config.crossfadeDuration
        }

        let baseDuration = config.crossfadeDuration

        // Bar-quantize: round to nearest bar boundary based on outgoing BPM
        let barInterval: Double
        if let bpm = fromAnalysis.bpm, bpm > 0 {
            barInterval = 240.0 / bpm  // 4 beats per bar
        } else {
            barInterval = 2.0  // default: assume 120 BPM
        }

        let fromEnergy = fromAnalysis.averageRMS
        let toEnergy = toAnalysis.averageRMS
        let energyDiff = abs(fromEnergy - toEnergy)

        var rawDuration: Double
        if energyDiff > 0.15 {
            rawDuration = baseDuration * 0.65
        } else {
            let compat = MixEngine.scoreCompatibility(a: fromAnalysis, b: toAnalysis)
            if compat > 0.85 {
                rawDuration = baseDuration * 1.3
            } else {
                let outHasVocals = fromAnalysis.hasVocals
                let inHasVocals = toAnalysis.hasVocals
                if inHasVocals && !outHasVocals {
                    rawDuration = baseDuration * 1.15
                } else {
                    rawDuration = baseDuration
                }
            }
        }

        // Quantize to nearest bar boundary (minimum 2 bars)
        let bars = max(2.0, round(rawDuration / barInterval))
        return bars * barInterval
    }

    // MARK: - Vocal Overlap Prevention

    /// Finds the optimal point in the incoming track to connect vocals.
    /// Returns a timestamp shortly BEFORE the first vocal onset so the incoming
    /// has a brief instrumental build-up before the vocal hits — seamless
    /// vocal-to-vocal without starting abruptly.
    private func findVocalConnectionPoint(
        outgoing: TrackAnalysis?,
        incoming: TrackAnalysis?,
        crossfadeDuration: Double
    ) -> Double {
        guard let incoming = incoming else { return 0 }

        let leadInDuration = max(crossfadeDuration + 0.5, 2.0)
        let result: Double

        // Priority 1: Lead-in before first vocal onset
        // vocalOnsetTimestamps come from RMS energy detection (beats/drums
        // included).  Validate each onset against the spectral vocalActivity
        // array so rap percussion is not mistaken for voice.
        // Also skip tracks with sustained vocal presence (rap/spoken-word):
        // look for a vocal gap BEFORE the onset, not just the onset itself.
        let validatedOnset = incoming.vocalOnsetTimestamps.first { onset in
            guard onset > 0, !incoming.vocalActivity.isEmpty else { return onset > 0 }
            let idx = max(0, min(incoming.vocalActivity.count - 1,
                Int(onset / max(1, incoming.duration) * Double(incoming.vocalActivity.count))))
            guard incoming.vocalActivity[idx] > 0.5 else { return false }
            // Confirm there was a vocal gap before this onset — if vocal
            // activity has been sustained (rap), skip to avoid wrong landing.
            let lookbackSamples = max(0, idx - 3)
            for j in lookbackSamples..<idx {
                if incoming.vocalActivity[j] < 0.25 { return true }
            }
            return false
        }
        if let firstOnset = validatedOnset {
            result = max(0, firstOnset - leadInDuration)
        // Priority 2: Intro region end
        } else if let intro = incoming.introRegion {
            let introEnd = intro.end
            if introEnd > 0 { result = introEnd } else { return 0 }
        // Priority 3: First energy peak
        } else {
            let energy = incoming.energyProfile
            if !energy.isEmpty {
                let threshold = energy.max() ?? 0.5
                var found = false
                var firstEnergyTime: Double = 0
                for (i, e) in energy.enumerated() {
                    if e > threshold * 0.5 {
                        let timePerSample = incoming.duration / Double(max(1, energy.count * 2))
                        firstEnergyTime = Double(i) * timePerSample
                        found = true
                        break
                    }
                }
                if found { result = firstEnergyTime } else { return 0 }
            } else { return 0 }
        }

        // Cap: never skip more than 20% of track or 45s (whichever is smaller).
        let cap = min(incoming.duration * 0.2, 45.0)
        return min(result, cap)
    }
}
