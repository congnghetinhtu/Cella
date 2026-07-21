import AVFoundation

enum AudioProfile: String, CaseIterable, Sendable {
    case flat
    case bose
    case sony
    case apple
    case sennheiser
    case beats
    case jbl
    case akg

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
        case .apple: return "Apple"
        case .sennheiser: return "Sennheiser"
        case .beats: return "Beats"
        case .jbl: return "JBL"
        case .akg: return "AKG"
        }
    }

    var iconName: String {
        switch self {
        case .flat: return "waveform.path"
        case .bose: return "hifispeaker.fill"
        case .sony: return "headphones"
        case .apple: return "airpods.max"
        case .sennheiser: return "earbuds"
        case .beats: return "speaker.wave.3.fill"
        case .jbl: return "speaker.fill"
        case .akg: return "mic.fill"
        }
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
        // Apple: near-neutral, slight sub-bass warmth, flat mids + highs
        case .apple:
            return [(31, 1), (62, 2), (125, 1), (250, 0), (500, 0),
                    (1000, 0), (2000, 0), (4000, 0), (8000, 0), (16000, 0)]
        // Sennheiser: reference flat, slight air at top
        case .sennheiser:
            return [(31, 0), (62, 0), (125, 0), (250, 0), (500, 0),
                    (1000, 0), (2000, 0), (4000, 0), (8000, 1), (16000, 1)]
        // Beats: extreme V-shape — heavy bass, scooped mids, bright highs
        case .beats:
            return [(31, 6), (62, 8), (125, 6), (250, 0), (500, -4),
                    (1000, -4), (2000, -2), (4000, 3), (8000, 5), (16000, 5)]
        // JBL: warm with vocal presence bump
        case .jbl:
            return [(31, 2), (62, 3), (125, 3), (250, 1), (500, 0),
                    (1000, 1), (2000, 3), (4000, 2), (8000, 1), (16000, 0)]
        // AKG: neutral-analytical, slight treble air, spacious
        case .akg:
            return [(31, -1), (62, 0), (125, 0), (250, 0), (500, 0),
                    (1000, 0), (2000, 1), (4000, 2), (8000, 2), (16000, 2)]
        }
    }
}
