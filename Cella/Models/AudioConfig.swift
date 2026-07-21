//
//  AudioConfig.swift
//  Cella
//
//  Global audio configuration for the automix engine.
//

import Foundation
import AVFoundation

struct AudioConfig {
    /// Sample rate for audio processing (Hz).
    var sampleRate: Double = 44100

    /// Buffer size for real-time audio rendering.
    var bufferSize: AVAudioFrameCount = 4096

    /// Default crossfade duration in seconds.
    var crossfadeDuration: Double = 8.0

    /// Maximum allowed BPM adjustment as a percentage (0.0–1.0).
    var maxBpmAdjustment: Double = 0.15

    /// Number of concurrent analysis operations.
    var maxConcurrentAnalysis: Int = 3

    /// Maximum pitch shift per chunk in semitones (subtle correction).
    var maxPitchShiftPerChunk: Double = 0.25

    /// Maximum total pitch shift in semitones (conservative limit).
    var maxTotalPitchShift: Double = 2.0

    /// Maximum tempo change per chunk as a ratio (0.02 = 2%).
    var maxTempoChangePerChunk: Double = 0.02

    /// Target LUFS for normalization.
    var targetLUFS: Double = -20.0

    /// Soft compression ratio above threshold.
    var compressionRatio: Float = 3.0

    /// Compression threshold (linear amplitude).
    var compressionThreshold: Float = 0.85

    /// Maximum gain boost in dB.
    var maxGainBoostDB: Float = 6.0

    /// Maximum gain reduction in dB.
    var maxGainReductionDB: Float = -10.0

    /// Enable spectral blend (EQ sweep) during crossfade.
    /// Disabled by default — gentle volume curve + loudness match already sound
    /// natural. Enable only if you want the DJ filter-fade character.
    var eqFadeEnabled: Bool = false

    /// Low-pass filter start cutoff (Hz) — outgoing starts here at progress=0.
    var eqLowPassStartHz: Float = 20000.0

    /// Low-pass filter end cutoff (Hz) — outgoing reaches here at progress=1.
    /// 5000 = gentle high roll-off, 200 = aggressive filter-close.
    var eqLowPassEndHz: Float = 5000.0

    /// High-pass filter start cutoff (Hz) — incoming starts here at progress=0.
    /// 50 = barely rolls off sub-bass, 500 = telephone effect.
    var eqHighPassStartHz: Float = 50.0

    /// High-pass filter end cutoff (Hz) — incoming reaches here at progress=1.
    var eqHighPassEndHz: Float = 20.0

    /// Final mix peak limit (linear).
    var finalPeakLimit: Float = 0.95

    /// Final mix gain range (min, max).
    var finalGainRange: (min: Float, max: Float) = (0.8, 1.2)

    /// The audio processing format used throughout the engine.
    var processingFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
            ?? AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    }

    nonisolated static let standard = AudioConfig()
}
