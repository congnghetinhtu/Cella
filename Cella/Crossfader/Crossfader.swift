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

/// Whether a transition was triggered automatically at track end or manually by the user.
enum TransitionContext: Sendable {
    case automatic
    case manualSkip
}

/// Parameters for a crossfade transition.
struct CrossfadeParams: Sendable {
    /// Duration of the crossfade in seconds.
    let duration: Double

    /// Crossfade point in the outgoing track (seconds from start).
    let crossfadeStart: Double

    /// Context-aware DJ transition style selected for this track pair.
    let style: TransitionStyle

    /// Human-readable reason explaining why this style was selected (for debug logs).
    let styleReason: String

    /// Whether the incoming track should be beat-phase-aligned to an outgoing bar line.
    /// False for free-time/ambient transitions where forcing a beat pad feels unnatural.
    let beatPhaseLock: Bool

    /// Vocal transition strategy for this crossfade.
    let vocalStrategy: VocalTransitionStrategy

    /// Transition log entry for this crossfade.
    let transitionLog: TransitionLog

    /// Whether the incoming track's intro should be skipped to align energy/vocals.
    let skipIntro: Bool

    /// Actual entry point in incoming track (seconds, always >= leadingSilence).
    let vocalConnectionPoint: Double

    /// Gain compensation for incoming track (1.0 = no change). Computed from LUFS/RMS difference.
    let incomingGainCompensation: Double

    /// Gain compensation for outgoing track (1.0 = no change).
    let outgoingGainCompensation: Double

    /// Incoming playback rate during the blend (1.0 = natural tempo).
    /// Computed from outgoing/incoming BPM (harmonic-aware); applied to the
    /// incoming timePitch node only when beat-sync is active, then glided back to 1.0.
    let tempoRate: Double

    /// False when the BPM gap fits no direct or harmonic ratio within
    /// `maxBpmAdjustment`, or when beat confidence is too low to beatmatch.
    let tempoCompatible: Bool
}

/// Renders crossfade buffers with tempo alignment, vocal-aware EQ, and context-aware DJ styles.
struct Crossfader {
    let config: AudioConfig

    init(config: AudioConfig = .standard) {
        self.config = config
    }

    // MARK: - Crossfade Parameter Computation

    /// Computes crossfade parameters for a transition between two tracks.
    func computeCrossfadeParams(
        outgoing: TrackAsset,
        incoming: TrackAsset,
        context: TransitionContext = .automatic
    ) -> CrossfadeParams {
        let outAnalysis = outgoing.analysis
        let inAnalysis = incoming.analysis

        let outConf = outAnalysis?.beatConfidence ?? 0
        let inConf = inAnalysis?.beatConfidence ?? 0
        let bothRhythmic = outConf >= config.minBeatConfidenceForSync && inConf >= config.minBeatConfidenceForSync

        // Tempo match FIRST: only beat-sync when both tracks have reliable beats.
        let rawMatch = Self.computeTempoMatch(
            outBPM: outAnalysis?.bpm,
            inBPM: inAnalysis?.bpm,
            maxAdjustment: config.maxBpmAdjustment
        )
        let tempoCompatible = bothRhythmic && rawMatch.compatible

        // Select context-aware transition style (Bass-Swap, Beatmatch, Echo-Out, Ambient, Quick Cut).
        let decision = selectTransitionStyle(
            outgoing: outAnalysis,
            incoming: inAnalysis,
            bothRhythmic: bothRhythmic,
            tempoCompatible: tempoCompatible,
            context: context
        )

        let effectiveTempoRate = decision.useTempoSync ? rawMatch.rate : 1.0

        let crossfadeDuration = Self.computeCrossfadeDuration(
            from: outgoing,
            to: incoming,
            config: config,
            style: decision.style,
            tempoRate: effectiveTempoRate,
            tempoCompatible: tempoCompatible,
            context: context
        )

        // Crossfade starts near the end of the outgoing track (anchored to trailingSilence when known).
        let crossfadeStart: Double
        if let out = outAnalysis, out.duration > 0 {
            let effectiveEnd = out.trailingSilence > 1.0 ? min(out.duration, out.trailingSilence) : out.duration
            crossfadeStart = max(0, effectiveEnd - crossfadeDuration)
        } else {
            crossfadeStart = 0
        }

        // Determine vocal transition strategy
        let vocalStrategy = computeVocalStrategy(
            outgoing: outAnalysis,
            incoming: inAnalysis
        )

        // Find where the incoming track should enter: always trims dead leading silence,
        // and skips longer intros when a bar-aligned seam fits better without cutting vocals.
        let leadingSilence = inAnalysis?.leadingSilence ?? 0
        let connectionPoint = findConnectionPoint(
            outgoing: outAnalysis,
            incoming: inAnalysis,
            crossfadeDuration: crossfadeDuration,
            context: context
        )

        // Flag intro skip only when skipping meaningful musical intro beyond dead silence.
        let skipIntro = connectionPoint > max(0.5, leadingSilence + 0.5)

        // Compute loudness-matching gain compensation
        let (outGain, inGain) = computeGainCompensation(
            outgoing: outAnalysis,
            incoming: inAnalysis
        )

        // Build rich transition log
        let transitionLog = TransitionLog(
            fromTrack: outgoing.url,
            toTrack: incoming.url,
            crossfadeDuration: crossfadeDuration,
            style: decision.style,
            reason: decision.reason,
            tempoRate: effectiveTempoRate,
            incomingEntryTime: connectionPoint,
            outBeatConfidence: outConf,
            inBeatConfidence: inConf,
            bpmAdjusted: abs(effectiveTempoRate - 1.0) > 0.001,
            keyCorrected: false,
            vocalDuckingApplied: vocalStrategy != .standard
        )

        return CrossfadeParams(
            duration: crossfadeDuration,
            crossfadeStart: crossfadeStart,
            style: decision.style,
            styleReason: decision.reason,
            beatPhaseLock: decision.beatPhaseLock,
            vocalStrategy: vocalStrategy,
            transitionLog: transitionLog,
            skipIntro: skipIntro,
            vocalConnectionPoint: connectionPoint,
            incomingGainCompensation: inGain,
            outgoingGainCompensation: outGain,
            tempoRate: effectiveTempoRate,
            tempoCompatible: tempoCompatible
        )
    }

    // MARK: - Context-Aware Transition Style Selection

    private struct StyleDecision {
        let style: TransitionStyle
        let reason: String
        let useTempoSync: Bool
        let beatPhaseLock: Bool
    }

    private func selectTransitionStyle(
        outgoing: TrackAnalysis?,
        incoming: TrackAnalysis?,
        bothRhythmic: Bool,
        tempoCompatible: Bool,
        context: TransitionContext
    ) -> StyleDecision {
        guard let out = outgoing, let inn = incoming else {
            return StyleDecision(
                style: .ambientBlend,
                reason: "missing analysis → safe ambient blend",
                useTempoSync: false,
                beatPhaseLock: false
            )
        }

        let outMood = MusicMood.from(analysis: out)
        let inMood = MusicMood.from(analysis: inn)
        let outEnergetic = outMood == .energeticHappy || outMood == .energeticAngry
        let inEnergetic = inMood == .energeticHappy || inMood == .energeticAngry
        let moodClash = outEnergetic != inEnergetic
        let keyScore = MixEngine.keyCompatibility(a: out, b: inn)
        let energyDiff = abs(out.averageRMS - inn.averageRMS)

        // 1. Free-time / Ballad / Acoustic (low beat confidence on either track):
        // Never force time-stretching or beat-grid locking.
        if !bothRhythmic {
            if outEnergetic && !inEnergetic {
                return StyleDecision(
                    style: .echoOut,
                    reason: "free-time handoff from energetic track → reverb echo-out",
                    useTempoSync: false,
                    beatPhaseLock: false
                )
            }
            return StyleDecision(
                style: .ambientBlend,
                reason: "low beat confidence (out=\(String(format: "%.2f", out.beatConfidence)), in=\(String(format: "%.2f", inn.beatConfidence))) → ambient blend",
                useTempoSync: false,
                beatPhaseLock: false
            )
        }

        // 2. Incompatible BPM (>15% even with harmonic ratios):
        // Avoid distorted time-stretching; use Echo-Out or a crisp Quick Phrase Cut.
        if !tempoCompatible {
            if outEnergetic && inEnergetic && energyDiff < 0.12 && context == .automatic {
                return StyleDecision(
                    style: .quickPhraseCut,
                    reason: "incompatible BPM + matching high energy → quick phrase cut",
                    useTempoSync: false,
                    beatPhaseLock: true
                )
            }
            return StyleDecision(
                style: .echoOut,
                reason: "incompatible BPM → echo-out (no time-stretch)",
                useTempoSync: false,
                beatPhaseLock: false
            )
        }

        // 3. Severe Harmonic Key Clash:
        // Preserve original pitch (0 semitone), mask harmonic clash via rhythmic Echo-Out
        // (reverb tail dissolves outgoing harmony, incoming drops cleanly on the bar line).
        if keyScore < 0.35 {
            return StyleDecision(
                style: .echoOut,
                reason: "harmonic key clash (score=\(String(format: "%.2f", keyScore))) → rhythmic echo-out",
                useTempoSync: false,
                beatPhaseLock: true
            )
        }

        // 4. Both rhythmic, BPM & key compatible (including smooth calm→energetic builds):
        // Choose Bass-Swap if both carry clear low-end, otherwise Beatmatch Blend.
        let outBass = Self.edgeBassEnergy(out, useEnd: true)
        let inBass = Self.edgeBassEnergy(inn, useEnd: false)
        if outBass >= 0.28 && inBass >= 0.28 {
            return StyleDecision(
                style: .bassSwap,
                reason: "beatmatch + low-end (bass out=\(String(format: "%.2f", outBass)), in=\(String(format: "%.2f", inBass))) → bass swap",
                useTempoSync: true,
                beatPhaseLock: true
            )
        }

        return StyleDecision(
            style: .beatmatchBlend,
            reason: "rhythmic + BPM/key compatible (key=\(String(format: "%.2f", keyScore))\(moodClash ? ", energy-shift" : "")) → beatmatch blend",
            useTempoSync: true,
            beatPhaseLock: true
        )
    }

    private static func edgeBassEnergy(_ analysis: TrackAnalysis, useEnd: Bool) -> Float {
        let bass = analysis.bassEnergyProfile
        guard !bass.isEmpty else { return 0 }
        let dur = max(0.1, analysis.duration)
        let n = bass.count
        let window = min(20, max(1, n / 8))
        if useEnd {
            let trail = analysis.trailingSilence > 1.0 ? min(dur, analysis.trailingSilence) : dur
            let endIdx = max(1, min(n, Int((trail / dur) * Double(n))))
            let startIdx = max(0, endIdx - window)
            let slice = bass[startIdx..<endIdx]
            return slice.reduce(0, +) / Float(max(1, slice.count))
        } else {
            let startIdx = max(0, min(n - 1, Int((analysis.leadingSilence / dur) * Double(n))))
            let endIdx = min(n, startIdx + window)
            let slice = bass[startIdx..<endIdx]
            return slice.reduce(0, +) / Float(max(1, slice.count))
        }
    }

    // MARK: - Tempo Match (beat-fit)

    /// Finds the incoming playback rate that beat-matches the outgoing track.
    /// Tries the direct ratio plus harmonic targets (half/double-time, 3:2)
    /// and keeps the smallest adjustment within `maxAdjustment`.
    /// Returns rate 1.0 + incompatible when nothing fits — the caller then
    /// plays a short bar-aligned cut instead of a drifting blend.
    static func computeTempoMatch(
        outBPM: Double?,
        inBPM: Double?,
        maxAdjustment: Double
    ) -> (rate: Double, compatible: Bool) {
        guard let out = outBPM, out > 0, let inn = inBPM, inn > 0 else {
            return (1.0, true)
        }
        let targets = [out, out * 2, out / 2, out * 1.5, out / 1.5]
        // Start with the DIRECT ratio — its adjustment is exactly what the
        // loop compares against, so with bestRate=1.0 the direct fit could
        // never win (`adjust < bestAdjust` was false) and every blend silently
        // played at natural tempo instead of beat-matched.
        let directRate = out / inn
        var bestRate: Double = (directRate > 0.25 && directRate < 4.0) ? directRate : 1.0
        var bestAdjust = abs(bestRate - 1.0)
        for target in targets {
            let rate = target / inn
            guard rate > 0.25, rate < 4.0 else { continue }
            let adjust = abs(rate - 1.0)
            if adjust < bestAdjust {
                bestAdjust = adjust
                bestRate = rate
            }
        }
        guard bestAdjust <= maxAdjustment else { return (1.0, false) }
        return (bestRate, true)
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
        config: AudioConfig,
        style: TransitionStyle,
        tempoRate: Double,
        tempoCompatible: Bool,
        context: TransitionContext
    ) -> Double {
        let outBar: Double
        if let bpm = from.analysis?.bpm, bpm > 0 {
            outBar = 240.0 / bpm  // 4 beats per bar
        } else {
            outBar = 2.0  // default: assume 120 BPM
        }

        // Responsive manual skip: fast, musical 3–5s handoff (1–2 bars when rhythmic).
        if context == .manualSkip {
            let minD = config.manualSkipMinDuration
            let maxD = config.manualSkipMaxDuration
            switch style {
            case .bassSwap, .beatmatchBlend, .quickPhraseCut:
                let twoBars = outBar * 2.0
                if twoBars >= minD && twoBars <= maxD { return twoBars }
                let oneBar = outBar
                if oneBar >= minD && oneBar <= maxD { return oneBar }
                return min(maxD, max(minD, twoBars))
            case .echoOut:
                return 3.5
            case .ambientBlend:
                return 4.0
            }
        }

        // Style-specific automatic durations
        switch style {
        case .quickPhraseCut:
            let cut = outBar + (config.dreamyBlends ? outBar * 0.5 : 0)
            return min(4.5, max(2.0, cut))
        case .echoOut:
            // Enough room for the reverb tail to bloom and decay naturally
            let echoDur = min(6.5, max(4.2, outBar * 2.0))
            return echoDur
        case .ambientBlend:
            return min(9.0, max(5.5, config.crossfadeDuration * (config.dreamyBlends ? 1.0 : 0.85)))
        case .beatmatchBlend, .bassSwap:
            break
        }

        guard let fromAnalysis = from.analysis,
              let toAnalysis = to.analysis else {
            return config.crossfadeDuration
        }

        if !tempoCompatible {
            return outBar + (config.dreamyBlends ? outBar : 0)
        }

        let baseDuration = config.crossfadeDuration
        let barInterval = outBar

        let fromEnergy = fromAnalysis.averageRMS
        let toEnergy = toAnalysis.averageRMS
        let energyDiff = abs(fromEnergy - toEnergy)

        // Energy slope: direction of energy at transition boundaries
        let outSlope = energySlope(fromAnalysis.energyProfile, at: .end)
        let inSlope = energySlope(toAnalysis.energyProfile, at: .start)
        let slopeMatch = 1.0 - min(1.0, abs(outSlope - inSlope) * 5.0)

        var rawDuration: Double
        if energyDiff > 0.15 {
            // Large energy gap — shorter crossfade, less overlap time for jarring transition.
            // Dreamy mode cuts less aggressively.
            rawDuration = baseDuration * (config.dreamyBlends ? 0.85 : 0.65)
        } else if slopeMatch > 0.8 && energyDiff < 0.08 {
            // Energy levels AND trajectories match — longer crossfade for seamless blend
            rawDuration = baseDuration * 1.25
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

        // Quantize to whole bars on BOTH grids (minimum 2 outgoing bars).
        // With tempo-match the incoming grid is stretched to the outgoing
        // tempo, so snap the length until it lands near a bar line on each
        // side. Dreamy blends stretch one extra bar, staying quantized.
        let bars = max(2.0, round(rawDuration / barInterval))
        var bestBars = bars
        if let inBPM = toAnalysis.bpm, inBPM > 0, tempoRate > 0 {
            let inBar = 240.0 / (inBPM * tempoRate)
            var bestErr = Double.greatestFiniteMagnitude
            let lo = max(2, Int(bars) - 2)
            for n in lo...(Int(bars) + 4) {
                let inBars = Double(n) * barInterval / inBar
                let err = abs(inBars - inBars.rounded())
                if err < bestErr - 0.001
                    || (abs(err - bestErr) <= 0.001 && abs(Double(n) - bars) < abs(bestBars - bars)) {
                    bestErr = err
                    bestBars = Double(n)
                }
            }
            // Don't stretch absurdly far chasing the incoming grid.
            if bestBars * barInterval > rawDuration * 2.0 + barInterval {
                bestBars = bars
            }
        }
        return bestBars * barInterval + (config.dreamyBlends ? barInterval : 0)
    }

    /// Energy slope: positive = rising, negative = falling.
    /// Computed from the last/first 12 samples of the energy profile.
    private enum SlopeRegion { case start, end }

    private static func energySlope(_ profile: [Float], at region: SlopeRegion) -> Double {
        guard profile.count >= 6 else { return 0 }
        let count = min(12, profile.count / 4)
        let slice: [Float]
        switch region {
        case .start:
            slice = Array(profile.prefix(count))
        case .end:
            slice = Array(profile.suffix(count))
        }
        guard slice.count >= 2 else { return 0 }
        let mid = slice.count / 2
        let first = Double(slice[..<(slice.count - mid)].reduce(0, +)) / Double(max(1, slice.count - mid))
        let second = Double(slice[(slice.count - mid)...].reduce(0, +)) / Double(max(1, mid))
        return second - first
    }

    // MARK: - Energy-Matched Entry Point

    /// Where the incoming track should start so its opening energy meets the
    /// outgoing ending — ideally a slight build, never a hard drop. Always trims
    /// dead leading silence (`incoming.leadingSilence`); skips longer intros only
    /// when a bar-aligned seam fits better without ever cutting into vocals.
    private func findConnectionPoint(
        outgoing: TrackAnalysis?,
        incoming: TrackAnalysis?,
        crossfadeDuration: Double,
        context: TransitionContext = .automatic
    ) -> Double {
        guard let incoming else { return 0 }
        let silenceFloor = min(incoming.leadingSilence, max(0, incoming.duration * 0.2))

        // On manual skip, keep the natural start (just trim dead leading silence)
        // so the user hears the song they clicked from the beginning.
        if context == .manualSkip {
            return silenceFloor
        }

        let vocalPoint = max(
            silenceFloor,
            findVocalConnectionPoint(
                outgoing: outgoing,
                incoming: incoming,
                crossfadeDuration: crossfadeDuration
            )
        )
        guard let out = outgoing,
              !out.energyProfile.isEmpty,
              !incoming.energyProfile.isEmpty else { return vocalPoint }

        let outEnd = Self.segmentAverage(out.energyProfile, suffix: 24)
        let target = outEnd + MixTuning.energyBuildDelta
        let profile = incoming.energyProfile
        let sampleDuration = incoming.duration / Double(max(1, profile.count))
        let cap = min(incoming.duration * 0.35, 45.0)

        func localEnergy(at time: Double) -> Float {
            let begin = max(0, min(profile.count - 1, Int(time / max(sampleDuration, 0.0001))))
            let length = max(1, Int(2.0 / max(sampleDuration, 0.0001)))
            let end = min(profile.count, begin + length)
            guard begin < end else { return 0 }
            return profile[begin..<end].reduce(0, +) / Float(end - begin)
        }

        func localSlope(at time: Double) -> Double {
            let window = max(2, profile.count / 40)
            let center = max(0, min(profile.count - 1, Int(time / max(sampleDuration, 0.0001))))
            let lo = max(0, center - window)
            let hi = min(profile.count - 1, center + window)
            return Double(profile[hi]) - Double(profile[lo])
        }

        func vocalLevel(at time: Double) -> Float {
            guard !incoming.vocalActivity.isEmpty else { return 0 }
            let index = max(0, min(incoming.vocalActivity.count - 1,
                Int(time / max(1, incoming.duration) * Double(incoming.vocalActivity.count))))
            return incoming.vocalActivity[index]
        }

        let outSlope = Self.energySlope(out.energyProfile, at: .end)
        let slopeScale = max(abs(outSlope), 0.001)
        let moodBonus = (MusicMood.from(analysis: out) == MusicMood.from(analysis: incoming)) ? 0.05 : 0

        // Mood-aware seam score: energy fit * level + slope-direction fit * ramp.
        func entryScore(_ time: Double) -> Double {
            let fit = Self.seamEnergyFit(incoming: localEnergy(at: time), target: target)
            let inSlope = localSlope(at: time)
            let slopeFit = 1.0 - min(1.0, abs((outSlope / slopeScale) - (inSlope / max(abs(inSlope), 0.001))) / 2.0)
            let vocalCost = Double(vocalLevel(at: time)) * 0.08
            let skipCost = min(0.03, (max(0, time - silenceFloor) / max(cap, 1)) * 0.03)
            return fit * 0.7 + slopeFit * 0.3 + moodBonus - vocalCost - skipCost
        }

        // Signature Apple AutoMix intro cueing:
        // If the incoming track has a long instrumental/sparse intro before the
        // first vocal (e.g. > crossfadeDuration + 4s), cue into the bar right
        // before `firstVocalTime - crossfadeDuration` so the groove builds under
        // the outgoing track and the incoming vocal lands cleanly as the blend finishes.
        var firstVocalTime = incoming.vocalOnsetTimestamps.first ?? 0.0
        if firstVocalTime <= 0, !incoming.vocalActivity.isEmpty, incoming.duration > 0 {
            for (i, v) in incoming.vocalActivity.enumerated() where v > 0.35 {
                firstVocalTime = Double(i) * (incoming.duration / Double(incoming.vocalActivity.count))
                break
            }
        }
        if firstVocalTime > silenceFloor + crossfadeDuration + 4.0 {
            let targetEntry = max(silenceFloor, firstVocalTime - crossfadeDuration)
            let snappedEntry = Self.snapToBarBefore(targetEntry, bars: incoming.barTimestamps)
            let maxSkip = min(incoming.duration * 0.30, 35.0)
            let clamped = min(snappedEntry, maxSkip)
            if clamped > silenceFloor + 1.5 {
                return clamped
            }
        }

        // Keep the natural intro (after dead silence) only when it already fits tightly.
        let naturalScore = entryScore(silenceFloor)
        guard naturalScore < 0.82 else { return silenceFloor }

        var candidates = incoming.barTimestamps.filter { $0 > silenceFloor + 0.75 && $0 <= cap }
        if candidates.isEmpty {
            var point = silenceFloor + 2.0
            while point <= cap {
                candidates.append(point)
                point += 2.0
            }
        }
        if vocalPoint > silenceFloor + 0.75 {
            candidates.append(vocalPoint)
        }

        var bestPoint: Double = silenceFloor
        var bestScore = naturalScore
        for point in candidates {
            var score = entryScore(point)
            if abs(point - vocalPoint) < 0.05 { score += 0.08 }
            if score > bestScore + 0.0001 {
                bestScore = score
                bestPoint = point
            }
        }
        // Never enter past the first vocal onset.
        if firstVocalTime > 0, bestPoint > firstVocalTime {
            bestPoint = min(vocalPoint, max(silenceFloor, firstVocalTime - 1.0))
        }
        guard bestScore >= 0.58, bestPoint > silenceFloor + 0.5 else {
            return max(silenceFloor, min(vocalPoint, firstVocalTime > 0 ? max(silenceFloor, firstVocalTime - 1.0) : vocalPoint))
        }
        return max(silenceFloor, bestPoint)
    }

    /// 1.0 when the incoming level sits on the target; drops cost more than
    /// rises of the same size.
    private static func seamEnergyFit(incoming: Float, target: Float) -> Double {
        let delta = incoming - target
        let weight: Float = delta < 0 ? MixTuning.energyDropPenalty : 1.0
        return max(0.0, min(1.0, 1.0 - Double(abs(delta) * weight) * 3.0))
    }

    /// Average of the last `count` energy samples (seam window).
    private static func segmentAverage(_ profile: [Float], suffix count: Int) -> Float {
        let segment = profile.suffix(count)
        guard !segment.isEmpty else { return 0 }
        return segment.reduce(0, +) / Float(segment.count)
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

        // Beat-fit: snap the skip point to the nearest incoming bar line at
        // or before the raw point — never overshoot into the vocal/drop.
        // (No bars, or point before the first bar: keep the raw point.)
        let snapped = Self.snapToBarBefore(result, bars: incoming.barTimestamps)

        // Cap: never skip more than ~25s or 30% of the track — the song should
        // still sound like itself, and we must not jump over the vocals.
        let cap = min(incoming.duration * 0.3, 25.0)
        return min(snapped, cap)
    }

    /// Latest bar line at or before `time` (bars ascending). Falls back to
    /// `time` when there is no earlier bar.
    private static func snapToBarBefore(_ time: Double, bars: [Double]) -> Double {
        guard time > 0, !bars.isEmpty else { return time }
        var best = time
        for bar in bars {
            if bar <= time + 0.01 {
                best = bar
            } else {
                break
            }
        }
        return best
    }
}
