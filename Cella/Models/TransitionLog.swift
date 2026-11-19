//
//  TransitionLog.swift
//  Cella
//
//  Records what happened during a crossfade transition between two tracks.
//

import Foundation

/// Context-aware DJ transition style selected by the AutoMix planner.
enum TransitionStyle: String, Sendable, Codable {
    /// Beat-matched equal-power blend with smooth EQ roll-off and vocal mid-ducking.
    case beatmatchBlend
    /// Beat-matched blend with clean low-frequency bass swap at mid-phrase.
    case bassSwap
    /// Per-deck reverb/echo tail on outgoing track + clean incoming entry (no forced time-stretch).
    case echoOut
    /// Gentle equal-power + warm EQ blend without beat-grid lock (low beat confidence / free-time).
    case ambientBlend
    /// Short 1–2 bar rhythmic handoff for incompatible tempos that still share high energy.
    case quickPhraseCut
}

struct TransitionLog: Sendable, Identifiable {
    let id = UUID()
    let fromTrack: URL
    let toTrack: URL
    let crossfadeDuration: Double
    let style: TransitionStyle
    let reason: String
    let tempoRate: Double
    let incomingEntryTime: Double
    let outBeatConfidence: Float
    let inBeatConfidence: Float
    let bpmAdjusted: Bool
    let keyCorrected: Bool
    let vocalDuckingApplied: Bool
    let timestamp: Date

    init(
        fromTrack: URL,
        toTrack: URL,
        crossfadeDuration: Double,
        style: TransitionStyle = .beatmatchBlend,
        reason: String = "",
        tempoRate: Double = 1.0,
        incomingEntryTime: Double = 0,
        outBeatConfidence: Float = 0,
        inBeatConfidence: Float = 0,
        bpmAdjusted: Bool = false,
        keyCorrected: Bool = false,
        vocalDuckingApplied: Bool = false
    ) {
        self.fromTrack = fromTrack
        self.toTrack = toTrack
        self.crossfadeDuration = crossfadeDuration
        self.style = style
        self.reason = reason
        self.tempoRate = tempoRate
        self.incomingEntryTime = incomingEntryTime
        self.outBeatConfidence = outBeatConfidence
        self.inBeatConfidence = inBeatConfidence
        self.bpmAdjusted = bpmAdjusted
        self.keyCorrected = keyCorrected
        self.vocalDuckingApplied = vocalDuckingApplied
        self.timestamp = Date()
    }
}
