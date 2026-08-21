import AVFoundation

enum AudioProfile: String, CaseIterable, Sendable {
    case flat
    case bose
    case sony
    case airpodsMax

    struct Config: Sendable {
        var eqBands: [(freq: Float, gain: Float)]
    }

    var config: Config {
        Config(eqBands: eqCurve)
    }

    var displayName: String {
        switch self {
        case .flat: return "Flat"
        case .bose: return "Bose"
        case .sony: return "Sony"
        case .airpodsMax: return "AirPods Max"
        }
    }

    var iconName: String {
        switch self {
        case .flat: return "waveform.path"
        case .bose: return "hifispeaker.fill"
        case .sony: return "headphones"
        case .airpodsMax: return "airpods.max"
        }
    }

    var isSpecial: Bool {
        self == .airpodsMax
    }

    // MARK: - EQ Presets

    static let eqFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    private var eqCurve: [(Float, Float)] {
        switch self {
        case .flat:
            return Self.eqFrequencies.map { ($0, 0) }
        // Bose: warm-neutral, gentle bass shelf, smooth treble, no mid scoop
        case .bose:
            return [(31, 2), (62, 3), (125, 2), (250, 1), (500, 0),
                    (1000, 0), (2000, 0), (4000, 0), (8000, 1), (16000, 1)]
        // Sony: big bass, crisp treble, slightly recessed lower mids
        case .sony:
            return [(31, 4), (62, 6), (125, 4), (250, 1), (500, -1),
                    (1000, -1), (2000, 1), (4000, 3), (8000, 4), (16000, 3)]
        // AirPods Max: tailored — sub-bass warmth, clean mids, airy highs, spatial presence
        case .airpodsMax:
            return [(31, 3), (62, 2), (125, 1), (250, 0), (500, 1),
                    (1000, 2), (2000, 2), (4000, 3), (8000, 2), (16000, 3)]
        }
    }
}
