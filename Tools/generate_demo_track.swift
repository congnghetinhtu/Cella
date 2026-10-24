//
//  generate_demo_track.swift
//  Cella — iOS demo asset generator (not part of any app target)
//
//  Renders the 64-second ambient demo song ("Waterline") that ships with the
//  iOS app so the lyric view, progress bar and playing pill have something to
//  play on first launch. Output is a 16-bit PCM WAV; convert to AAC with:
//
//    swiftc -O generate_demo_track.swift -o /tmp/gendemo
//    /tmp/gendemo /tmp/waterline.wav
//    afconvert -f m4af -d aac -b 128000 /tmp/waterline.wav CellaDemo.m4a
//

import AVFoundation
import Foundation

let sampleRate = 44100
let duration = 64.0
let frameCount = Int(Double(sampleRate) * duration)

func hz(_ midi: Int) -> Double { 440.0 * pow(2.0, (Double(midi) - 69.0) / 12.0) }

struct Chord {
    let start: Double
    let notes: [Int]
    let root: Int
    let phrase: [Int]
}

// Abmaj7 → Fm7 → Dbmaj7 → Ebmaj7, twice.
let chords: [Chord] = [
    Chord(start: 0,  notes: [56, 60, 63, 67], root: 44, phrase: [80, 77, 75, 72]),
    Chord(start: 8,  notes: [53, 56, 60, 63], root: 41, phrase: [75, 72, 70, 68]),
    Chord(start: 16, notes: [49, 53, 56, 60], root: 37, phrase: [77, 75, 72, 75]),
    Chord(start: 24, notes: [51, 55, 58, 63], root: 39, phrase: [72, 75, 77, 80]),
    Chord(start: 32, notes: [56, 60, 63, 67], root: 44, phrase: [80, 77, 75, 72]),
    Chord(start: 40, notes: [53, 56, 60, 65], root: 41, phrase: [75, 72, 70, 72]),
    Chord(start: 48, notes: [49, 53, 56, 60], root: 37, phrase: [77, 80, 77, 75]),
    Chord(start: 56, notes: [51, 55, 58, 62], root: 39, phrase: [72, 75, 77, 72]),
]

var left = [Double](repeating: 0, count: frameCount)
var right = [Double](repeating: 0, count: frameCount)

/// One voice: additive partials with a raised-cosine attack/release envelope.
/// Slightly detuned L/R copies give the pad its width.
func addVoice(
    start: Double,
    hold: Double,
    midi: Int,
    amp: Double,
    attack: Double,
    release: Double,
    partials: [(ratio: Double, level: Double)],
    decay: Double = 0 // > 0: bells (exponential decay instead of sustain)
) {
    let s0 = max(0, Int(start * Double(sampleRate)))
    let len = decay > 0 ? min(3.0, hold) : hold
    let s1 = min(frameCount, Int((start + len) * Double(sampleRate)))
    guard s1 > s0 else { return }
    let freq = hz(midi)
    let twoPi = 2.0 * Double.pi
    for i in s0..<s1 {
        let t = Double(i - s0) / Double(sampleRate)
        var env: Double
        if decay > 0 {
            env = exp(-decay * t)
        } else {
            let a = attack > 0 ? min(1.0, t / attack) : 1.0
            let r = release > 0 ? min(1.0, (len - t) / release) : 1.0
            let eased = min(a, r)
            env = eased * eased * (3 - 2 * eased) // smoothstep
        }
        guard env > 0.0005 else { continue }
        var sample = 0.0
        for p in partials {
            let f = freq * p.ratio
            sample += sin(twoPi * f * 0.9985 * t + Double(midi)) * p.level
        }
        sample *= env * amp
        // tiny cross-feed keeps the pad centered; detune separates the sides
        left[i] += sample * 0.92 + sin(twoPi * freq * 1.0015 * t) * env * amp * 0.18
        right[i] += sample * 0.92 + sin(twoPi * freq * 1.0015 * t + 0.7) * env * amp * 0.18
    }
}

let padPartials: [(ratio: Double, level: Double)] = [(1.0, 1.0), (2.0, 0.22), (3.0, 0.08)]
let bellPartials: [(ratio: Double, level: Double)] = [(1.0, 1.0), (2.01, 0.32), (3.02, 0.1)]

for chord in chords {
    // Pad: one voice per chord tone.
    for midi in chord.notes {
        addVoice(start: chord.start, hold: 8.0, midi: midi, amp: 0.135,
                 attack: 1.8, release: 2.6, partials: padPartials)
    }
    // Sub root for weight.
    addVoice(start: chord.start, hold: 8.0, midi: chord.root, amp: 0.075,
             attack: 1.4, release: 2.8, partials: [(1.0, 1.0), (2.0, 0.12)])

    // Bells: four plucked notes per chord, alternating pan.
    let offsets = [1.0, 3.0, 4.5, 6.5]
    for (k, offset) in offsets.enumerated() {
        if k < chord.phrase.count {
            addVoice(start: chord.start + offset, hold: 3.0, midi: chord.phrase[k],
                     amp: 0.11, attack: 0, release: 0, partials: bellPartials, decay: 2.1)
        }
    }
}

// Water shimmer: low-passed noise with a slow tide LFO.
var seed: UInt64 = 0x9E3779B97F4A7C15
var lp = 0.0
for i in 0..<frameCount {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    let noise = Double(Int64(bitPattern: seed)) / Double(Int64.max)
    lp += 0.03 * (noise - lp)
    let t = Double(i) / Double(sampleRate)
    let tide = 0.5 + 0.5 * sin(2.0 * Double.pi * 0.06 * t)
    let s = lp * 0.014 * tide
    left[i] += s
    right[i] += lp * 0.012 * (1.0 - tide * 0.5)
}

// Normalize, then fade in/out.
var peak = 0.0
for i in 0..<frameCount {
    peak = max(peak, abs(left[i]), abs(right[i]))
}
let gain = peak > 0 ? 0.72 / peak : 1.0
let fadeIn = 1.2, fadeOut = 3.0
for i in 0..<frameCount {
    let t = Double(i) / Double(sampleRate)
    var g = gain
    if t < fadeIn { g *= t / fadeIn }
    if t > duration - fadeOut { g *= max(0, (duration - t) / fadeOut) }
    left[i] *= g
    right[i] *= g
}

let outURL = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "waterline.wav")
try? FileManager.default.removeItem(at: outURL)

/// Scoped so the AVAudioFile deallocates (finalizing the WAV header) before
/// the process exits — a live reference at exit leaves a zero-length header.
func writeWav(to outURL: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: Double(sampleRate),
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let file = try AVAudioFile(forWriting: outURL, settings: settings)
    let format = file.processingFormat
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
        FileHandle.standardError.write(Data("buffer alloc failed\n".utf8))
        exit(1)
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    let l = buffer.floatChannelData![0]
    let r = buffer.floatChannelData![1]
    for i in 0..<frameCount {
        l[i] = Float(left[i])
        r[i] = Float(right[i])
    }
    try file.write(from: buffer)
}

try writeWav(to: outURL)
print("wrote \(outURL.path) — \(frameCount) frames")
