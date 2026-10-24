import Foundation

/// Surround staging modes for the Cella Orquesta. Persisted as a raw string.
enum SurroundMode: String, CaseIterable, Sendable {
    case off
    case ampliado
    case teatro

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .ampliado: return "Ampliado"
        case .teatro: return "Teatro"
        }
    }

    var iconName: String {
        switch self {
        case .off: return "speaker.slash.fill"
        case .ampliado: return "arrow.left.and.right.circle.fill"
        case .teatro: return "theatermasks.fill"
        }
    }

    static let storageKey = "surroundMode"
}