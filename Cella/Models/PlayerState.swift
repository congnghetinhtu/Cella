//
//  PlayerState.swift
//  Cella
//
//  Defines the possible states of the music player indicator.
//

import Foundation

/// Music mood derived from BPM, energy, and key analysis.
enum MusicMood: String {
    case energeticHappy
    case energeticAngry
    case calmHappy
    case calmSad
    case neutral

    var animationSpeed: TimeInterval {
        switch self {
        case .energeticHappy: return 0.10
        case .energeticAngry:  return 0.12
        case .calmHappy:       return 0.25
        case .calmSad:         return 0.30
        case .neutral:         return 0.15
        }
    }

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
    /// No music activity — shows static smiley face
    case idle

    /// Music is playing — smiley face animates with breathing effect
    case playing

    /// Music is paused — smiley face is static with "Music Paused" info
    case paused

    /// Tracks are being analyzed — shows analyzing dot pattern
    case analyzing(progress: Double)

    /// Mix queue is being built — shows loading pattern
    case loading

    /// AutoMix state — shows automix pattern
    case autoMix

    /// Returns the next state when spacebar is pressed.
    /// Cycle: idle → playing → paused → playing → paused → ...
    var nextState: PlayerState {
        switch self {
        case .idle:    return .playing
        case .playing: return .paused
        case .paused:  return .playing
        case .analyzing, .loading, .autoMix: return self
        }
    }

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
