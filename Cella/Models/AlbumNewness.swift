import Foundation

/// Tracks which pack albums the user has already encountered, so newly added
/// albums can carry a "NEW" badge in the pack detail list until first opened.
///
/// Identity is pack path + album folder name (stable across rescans).
/// Each pack is baselined silently on first open — only albums appearing
/// afterwards ever badge.
enum AlbumNewness {
    private static let knownKey = "cella.knownAlbumKeys"
    private static let viewedKey = "cella.viewedAlbumKeys"
    private static let baselinedKey = "cella.baselinedPackPaths"
    private static let sep = "\u{1F}"

    static func key(packURL: URL, folderName: String) -> String {
        packURL.path + sep + folderName
    }

    /// Registers the currently present albums of a pack (pruning stale keys
    /// for deleted albums). Returns the keys that should badge as new.
    @discardableResult
    static func register(albums: [CellaAlbum], in packURL: URL) -> Set<String> {
        let ud = UserDefaults.standard
        var known = Set(ud.stringArray(forKey: knownKey) ?? [])
        var viewed = Set(ud.stringArray(forKey: viewedKey) ?? [])
        var baselined = Set(ud.stringArray(forKey: baselinedKey) ?? [])

        let prefix = packURL.path + sep
        let current = Set(albums.map { prefix + $0.folderName })

        // Drop keys for albums that no longer exist in this pack.
        known = known.filter { !$0.hasPrefix(prefix) || current.contains($0) }
        viewed = viewed.filter { !$0.hasPrefix(prefix) || current.contains($0) }

        // First open of this pack: seed silently so the existing library
        // doesn't badge everything at once.
        if !baselined.contains(packURL.path) {
            baselined.insert(packURL.path)
            known.formUnion(current)
            viewed.formUnion(current)
            save(known: known, viewed: viewed, baselined: baselined)
            return []
        }

        let fresh = current.subtracting(known)
        known.formUnion(current)
        save(known: known, viewed: viewed, baselined: baselined)
        return fresh.subtracting(viewed)
    }

    static func markViewed(packURL: URL, folderName: String) {
        markViewed(key: key(packURL: packURL, folderName: folderName))
    }

    static func markViewed(key: String) {
        let ud = UserDefaults.standard
        var viewed = Set(ud.stringArray(forKey: viewedKey) ?? [])
        guard !viewed.contains(key) else { return }
        viewed.insert(key)
        ud.set(Array(viewed), forKey: viewedKey)
    }

    private static func save(known: Set<String>, viewed: Set<String>, baselined: Set<String>) {
        let ud = UserDefaults.standard
        ud.set(Array(known), forKey: knownKey)
        ud.set(Array(viewed), forKey: viewedKey)
        ud.set(Array(baselined), forKey: baselinedKey)
    }
}
