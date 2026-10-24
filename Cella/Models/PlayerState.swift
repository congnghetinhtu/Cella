//
//  PlayerState.swift
//  Cella
//
//  Defines the possible states of the music player indicator.
//

import Foundation

/// Music mood derived from BPM, energy, and key analysis.
/// Consumed by the engine's mood-aware crossfade parameter computation.
enum MusicMood: String {
    case energeticHappy
    case energeticAngry
    case calmHappy
    case calmSad
    case neutral

    /// Determines mood from track analysis using adaptive thresholds.
    static func from(analysis: TrackAnalysis?) -> MusicMood {
        guard let a = analysis else {
            print("[Mood] No analysis → neutral")
            return .neutral
        }

        let bpm = a.bpm ?? 120
        let energy = a.energyProfile
        let isMajor = a.keySignature?.mode.lowercased() == "major"
        let hasKey = a.keySignature != nil

        // Adaptive energy threshold: median of energy profile
        let medianEnergy: Float
        if energy.isEmpty {
            medianEnergy = 0.3
        } else {
            let sorted = energy.sorted()
            medianEnergy = sorted[sorted.count / 2]
        }

        // Energy variance: high variance = dynamic (verse/chorus), low = flat
        let avgEnergy = energy.reduce(0, +) / Float(max(energy.count, 1))
        let variance = energy.reduce(0) { $0 + ($1 - avgEnergy) * ($1 - avgEnergy) } / Float(max(energy.count, 1))
        let isDynamic = variance > 0.01

        let fast = bpm >= 115
        let highEnergy = medianEnergy > 0.15

        let mood: MusicMood
        if fast && highEnergy {
            mood = hasKey ? (isMajor ? .energeticHappy : .energeticAngry) : .energeticHappy
        } else if fast && !highEnergy {
            mood = .calmHappy
        } else if !fast && highEnergy && isDynamic {
            mood = hasKey ? (isMajor ? .calmHappy : .energeticAngry) : .energeticAngry
        } else if !fast && highEnergy {
            mood = hasKey ? (isMajor ? .calmHappy : .calmSad) : .calmHappy
        } else {
            mood = hasKey ? (isMajor ? .calmHappy : .calmSad) : .calmSad
        }

        return mood
    }
}

enum PlayerState: Equatable {
    /// No music activity
    case idle

    /// Music is playing
    case playing

    /// Music is paused
    case paused

    /// Tracks are being analyzed
    case analyzing(progress: Double)

    /// Mix queue is being built
    case loading

    /// AutoMix transition in progress
    case autoMix

    /// Whether the player is in an active playback state.
    var isPlaying: Bool { self == .playing }

    /// Whether the player is in a transitional state.
    var isTransitioning: Bool {
        switch self {
        case .analyzing, .loading, .autoMix: return true
        default: return false
        }
    }
}

/// Lyrics display mode.
enum LyricsMode: Equatable {
    case off
    case full
    case slim

    mutating func cycle() {
        switch self {
        case .off:  self = .full
        case .full: self = .slim
        case .slim: self = .off
        }
    }

    var iconName: String {
        switch self {
        case .off:  return "text.bubble"
        case .full: return "text.bubble.fill"
        case .slim: return "text.badge.checkmark"
        }
    }

    var label: String {
        switch self {
        case .off:  return "Lyrics off"
        case .full: return "Full lyrics"
        case .slim: return "Slim lyrics"
        }
    }
}
