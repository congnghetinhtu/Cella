//
//  OrquestaDSP.swift
//  Cella
//
//  Shared Cella Orquesta DSP constants — the exact EQ geometry, surround
//  staging targets and stereo-width factors used by every Orquesta-capable
//  engine (the main mix engine and the preview mini player). Keeping them
//  in one place makes the preview sound identical to the Config tab.
//

import AVFoundation

enum OrquestaDSP {

    // MARK: - Profile EQ (10-band parametric)

    /// Bandwidth for each parametric profile band.
    static let profileBandwidth: Float = 0.5

    // MARK: - Surround staging

    /// The four surround-stage EQ bands: filter type + center frequency.
    static let surroundBands: [(type: AVAudioUnitEQFilterType, freq: Float)] = [
        (.lowShelf, 60),
        (.parametric, 400),
        (.parametric, 2500),
        (.highShelf, 10000),
    ]

    static let surroundBandwidth: Float = 0.6

    /// Gain targets (dB) per band for each staging mode.
    static func surroundTargets(for mode: SurroundMode) -> [Float] {
        switch mode {
        case .off: return [0, 0, 0, 0]
        case .ampliado: return [-2.5, -1.0, -2.0, 6.0]
        case .teatro: return [6.0, 2.0, -3.0, -1.5]
        }
    }

    /// Stereo width factor per mode. 1.0 = original stereo, >1 = wider.
    static func widthValue(for mode: SurroundMode) -> Float {
        switch mode {
        case .off: return 1.0
        case .ampliado: return 2.0
        case .teatro: return 1.5
        }
    }

    /// Half the max positive surround boost (dB) for a mode — engines reduce
    /// their profile-EQ global gain by this so the stacked EQs don't clip
    /// without killing volume.
    static func maxSurroundBoost(for mode: SurroundMode) -> Float {
        let full = surroundTargets(for: mode).max() ?? 0
        return max(0, full) / 2
    }
}
