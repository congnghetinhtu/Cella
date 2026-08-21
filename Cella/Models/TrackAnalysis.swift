//
//  TrackAnalysis.swift
//  Cella
//
//  Stores analysis results from spfk-* packages and computed audio features.
//

import Foundation
import AVFoundation

struct TrackAnalysis: Sendable {
    // MARK: - Audio Analysis Results

    /// Beats per minute detected by spfk-tempo.
    let bpm: Double?

    /// Beat positions as timestamps (seconds from start).
    let beatTimestamps: [Double]

    /// Bar boundary positions as timestamps (seconds from start).
    let barTimestamps: [Double]

    /// Musical key signature (tonic + mode) for the dominant range.
    let keySignature: KeySignature?

    /// Integrated loudness in LUFS (ITU-R BS.1770) via spfk-loudness.
    let loudnessIntegrated: Double?

    /// Song structure sections with time ranges and labels.
    let structureSections: [StructureSection]

    // MARK: - Computed Audio Features

    /// RMS energy envelope over time (one value per window).
    let energyProfile: [Float]

    /// Whether the track contains vocals.
    let hasVocals: Bool

    /// Per-window vocal activity level (0.0 = instrumental, 1.0 = vocals present).
    let vocalActivity: [Float]

    /// Total duration in seconds.
    let duration: Double

    // MARK: - Spectral Features (averages over analysis window)

    /// Spectral centroid (brightness) — weighted mean of frequencies. Higher = brighter.
    let spectralCentroid: Float

    /// Spectral rolloff — frequency below which 85% of energy is concentrated.
    let spectralRolloff: Float

    /// Spectral bandwidth — spread of frequencies around the centroid.
    let spectralBandwidth: Float

    /// Spectral flatness — ratio of geometric mean to arithmetic mean of power spectrum.
    /// Low = tonal, high = noisy/percussive.
    let spectralFlatness: Float

    // MARK: - Loudness & Gain

    /// Average RMS level across the entire analysis window.
    let averageRMS: Float

    /// Peak sample amplitude (0.0–1.0 linear scale).
    let peakAmplitude: Float

    // MARK: - Structure

    /// Intro region (start, end) in seconds. nil if not detected.
    let introRegion: (start: Double, end: Double)?

    /// Outro region (start, end) in seconds. nil if not detected.
    let outroRegion: (start: Double, end: Double)?

    // MARK: - Vocal Boundary Analysis

    /// Timestamps where vocal phrases begin (silence/gap → vocal onset).
    let vocalOnsetTimestamps: [Double]

    /// Timestamps where vocal phrases end (vocal → silence/gap).
    let vocalOffsetTimestamps: [Double]

    // MARK: - Convenience Types

    struct KeySignature: Sendable, Equatable {
        let tonic: String
        let mode: String

        /// Camelot wheel notation for harmonic mixing.
        var camelotNotation: String {
            let majorMap = ["C": "8B", "G": "9B", "D": "10B", "A": "11B", "E": "12B",
                           "B": "1B", "F#": "2B", "Db": "3B", "Ab": "4B", "Eb": "5B",
                           "Bb": "6B", "F": "7B"]
            let minorMap = ["Am": "8A", "Em": "9A", "Bm": "10A", "F#m": "11A", "C#m": "12A",
                           "G#m": "1A", "Abm": "1A", "D#m": "2A", "Ebm": "2A",
                           "Bbm": "3A", "Fm": "4A", "Cm": "5A",
                           "Gm": "6A", "Dm": "7A"]

            if mode.lowercased() == "major" {
                return majorMap[tonic] ?? "\(tonic) major"
            } else {
                return minorMap["\(tonic)m"] ?? "\(tonic) minor"
            }
        }

        /// Distance on Camelot wheel (0 = same key, 7 = most distant).
        func camelotDistance(to other: KeySignature) -> Int {
            let extractNumber: (String) -> Int? = { notation in
                let digits = notation.filter(\.isNumber)
                return Int(digits)
            }

            guard let selfNum = extractNumber(camelotNotation),
                  let otherNum = extractNumber(other.camelotNotation) else {
                return 12
            }

            let diff = abs(selfNum - otherNum)
            return min(diff, 12 - diff)
        }

        /// Semitone distance between two keys (considering circle of fifths and relative major/minor).
        /// Returns a value 0–11 where 0 = same key.
        func semitoneDistance(to other: KeySignature) -> Int {
            let noteToSemitone: [String: Int] = [
                "C": 0, "C#": 1, "Db": 1, "D": 2, "D#": 3, "Eb": 3,
                "E": 4, "F": 5, "F#": 6, "Gb": 6, "G": 7, "G#": 8,
                "Ab": 8, "A": 9, "A#": 10, "Bb": 10, "B": 11
            ]

            guard let selfSemitone = noteToSemitone[tonic],
                  let otherSemitone = noteToSemitone[other.tonic] else {
                return 6
            }

            let selfNote = selfSemitone
            let otherNote = otherSemitone

            let diff = abs(selfNote - otherNote)
            return min(diff, 12 - diff)
        }

    }

    struct StructureSection: Sendable {
        let startTime: Double
        let endTime: Double
        let label: String

        var duration: Double { endTime - startTime }
    }
}
