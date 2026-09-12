import Foundation

/// A curated Cella Orquesta preset — a complete audio mood that bundles the
/// look (theme), the sound (EQ curve) and the space (surround staging).
struct OrquestaPreset: Equatable, Sendable {
    let id: String
    let displayName: String
    let iconName: String
    let themeID: String
    let eqBands: [(freq: Float, gain: Float)]
    let surround: SurroundMode

    var isCustom: Bool { id == Self.customID }

    static func == (lhs: OrquestaPreset, rhs: OrquestaPreset) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Stage bands

    static let eqFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    // MARK: - Factory presets

    /// Reference: flat curve, dark stage, dry.
    static let natural = OrquestaPreset(
        id: "natural",
        displayName: "Natural",
        iconName: "waveform.path",
        themeID: "dark",
        eqBands: eqFrequencies.map { ($0, 0) },
        surround: .off
    )

    /// Warm vocal focus: gentle bass shelf, dark warm stage, wide.
    static let calido = OrquestaPreset(
        id: "calido",
        displayName: "Cálido",
        iconName: "flame.fill",
        themeID: "dark",
        eqBands: [(31, 2), (62, 3), (125, 2), (250, 1), (500, 0),
                  (1000, 0), (2000, 0), (4000, 0), (8000, 1), (16000, 1)],
        surround: .ampliado
    )

    /// Oceanic air: sub-warmth, clean mids, airy highs, seafoam stage, wide.
    static let oceano = OrquestaPreset(
        id: "oceano",
        displayName: "Océano",
        iconName: "water.waves",
        themeID: "seafoam",
        eqBands: [(31, 3), (62, 2), (125, 1), (250, 0), (500, 1),
                  (1000, 2), (2000, 2), (4000, 3), (8000, 2), (16000, 3)],
        surround: .ampliado
    )

    /// Colorful punch: big bass, crisp treble, bipolar stage, theater.
    static let aurora = OrquestaPreset(
        id: "aurora",
        displayName: "Aurora",
        iconName: "sparkles",
        themeID: "bipolar",
        eqBands: [(31, 4), (62, 6), (125, 4), (250, 1), (500, -1),
                  (1000, -1), (2000, 1), (4000, 3), (8000, 4), (16000, 3)],
        surround: .teatro
    )

    static let factoryPresets: [OrquestaPreset] = [natural, calido, oceano, aurora]

    // MARK: - Custom preset

    static let customID = "custom"

    /// Live custom preset — always reads the current saved curve.
    static var custom: OrquestaPreset {
        OrquestaPreset(
            id: customID,
            displayName: "Custom",
            iconName: "slider.horizontal.3",
            themeID: "dark",
            eqBands: customCurve,
            surround: .off
        )
    }

    /// Resolve a preset by id: factory presets or the live custom curve.
    static func resolve(_ id: String?) -> OrquestaPreset {
        guard let id else { return .natural }
        if let preset = factoryPresets.first(where: { $0.id == id }) { return preset }
        return .custom
    }

    static let storageKey = "orquestaPresetID"
    static let storageKeyEmpty = ""

    // MARK: - Custom curve (persisted across launches)

    private static let customGainsKey = "orquestaCustomGains"
    private static var customCache: [Float]?

    /// The 10 band gains for the user-drawn custom curve, 0 = flat.
    static var customCurve: [(freq: Float, gain: Float)] {
        zip(eqFrequencies, readCustomGains()).map { (freq: $0, gain: $1) }
    }

    static func saveCustomGains(_ gains: [Float]) {
        let clamped = normalizedGains(gains)
        customCache = clamped
        UserDefaults.standard.set(
            clamped.map { "\($0)" }.joined(separator: ","),
            forKey: customGainsKey
        )
    }

    static func resetCustomGains() {
        saveCustomGains(Array(repeating: 0, count: eqFrequencies.count))
    }

    static func readCustomGains() -> [Float] {
        if let cache = customCache { return cache }
        let fallback = Array(repeating: Float(0), count: eqFrequencies.count)
        guard let raw = UserDefaults.standard.string(forKey: customGainsKey) else {
            customCache = fallback
            return fallback
        }
        let parsed = raw.split(separator: ",").compactMap { Float($0) }
        let result = parsed.count == eqFrequencies.count ? parsed : fallback
        customCache = result
        return result
    }

    private static func normalizedGains(_ gains: [Float]) -> [Float] {
        let count = eqFrequencies.count
        guard !gains.isEmpty else { return Array(repeating: 0, count: count) }
        var out = Array(repeating: Float(0), count: count)
        for i in gains.indices where i < count {
            out[i] = min(6, max(-6, gains[i]))
        }
        if gains.count < count {
            for i in gains.count..<count {
                out[i] = gains.last ?? 0
            }
        }
        return out
    }
}