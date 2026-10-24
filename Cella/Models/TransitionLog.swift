//
//  TransitionLog.swift
//  Cella
//
//  Records what happened during a crossfade transition between two tracks.
//

import Foundation

struct TransitionLog: Sendable, Identifiable {
    let id = UUID()
    let fromTrack: URL
    let toTrack: URL
    let crossfadeDuration: Double
    let bpmAdjusted: Bool
    let keyCorrected: Bool
    let vocalDuckingApplied: Bool
    let timestamp: Date

    init(
        fromTrack: URL,
        toTrack: URL,
        crossfadeDuration: Double,
        bpmAdjusted: Bool = false,
        keyCorrected: Bool = false,
        vocalDuckingApplied: Bool = false
    ) {
        self.fromTrack = fromTrack
        self.toTrack = toTrack
        self.crossfadeDuration = crossfadeDuration
        self.bpmAdjusted = bpmAdjusted
        self.keyCorrected = keyCorrected
        self.vocalDuckingApplied = vocalDuckingApplied
        self.timestamp = Date()
    }
}
