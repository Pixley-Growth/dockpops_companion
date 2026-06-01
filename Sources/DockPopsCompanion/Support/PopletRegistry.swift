import Foundation

/// One entry in the Companion's Poplet registry, keyed by Pop UUID.
///
/// `filename` **tracks the current Pop name** (e.g. `"Work.app"`): the macOS
/// Dock labels a pinned tile from the `.app` filename, so on a Pop rename the
/// bundle is renamed on disk to `<newName>.app` — inode-preserving (see
/// `PopletRenameCore`), so the pin's bookmark follows and the tile both keeps
/// working AND shows the new label. `displayName` is the matching
/// `CFBundleDisplayName` / `CFBundleName`.
struct PopletRegistryEntry: Codable, Equatable, Sendable {
    let filename: String
    let displayName: String
}

/// Pure registry logic — no `FileManager`, no I/O — so migration, filename
/// resolution, and the orphan-sweep selection are unit-testable in isolation.
enum PopletRegistry {
    /// `pop.id.uuidString` → entry.
    typealias Map = [String: PopletRegistryEntry]

    /// Decode the current UUID-keyed shape, or migrate the legacy
    /// `[name → uuidString]` shape into it.
    ///
    /// Legacy entries adopt the filename `"<name>.app"` — the bundle that is
    /// actually on disk — with `displayName = name`; a later rename moves it.
    static func decode(_ data: Data) throws -> Map {
        // Try the current shape first. A legacy `[String: String]` payload has
        // string values where this expects objects, so its decode throws and
        // `try?` falls through to the migration branch. An empty `{}` decodes
        // here as an empty map, which is correct either way.
        if let modern = try? JSONDecoder().decode(Map.self, from: data) {
            return modern
        }
        let legacy = try JSONDecoder().decode([String: String].self, from: data)
        var migrated = Map()
        for (name, uuidString) in legacy {
            migrated[uuidString] = PopletRegistryEntry(
                filename: "\(name).app",
                displayName: name
            )
        }
        return migrated
    }

    /// Deterministic, byte-stable encoding. `.sortedKeys` keeps the bytes
    /// identical across syncs for an unchanged map so the App Group mirror
    /// write does not re-trigger `SharedContainerWatcher` and loop the sync —
    /// the invariant the recent idempotency commits established.
    static func encode(_ map: Map) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(map)
    }

    /// Collision-free display names keyed by Pop UUID — drives BOTH the on-disk
    /// `<name>.app` filename (the Dock label) AND the bundle's
    /// CFBundleDisplayName/CFBundleName. Sanitizes each name and uniquifies
    /// duplicates with a ` <n>` suffix, processing in the given (stable) order
    /// so the FIRST occurrence keeps the bare name and only later duplicates get
    /// ` 2`, ` 3`, … This keeps the *primary* Pop named "Work" resolvable as
    /// `Work.app` — the exact filename the unchanged MAS reader looks for (a
    /// second same-named Pop becomes `Work 2.app`, the documented limitation).
    /// A name freed by a deletion is reused next sync. Pure → unit-testable.
    static func resolvedDisplayNames(
        for items: [(id: UUID, name: String)],
        sanitize: (String) -> String
    ) -> [UUID: String] {
        var names: [UUID: String] = [:]
        var used = Set<String>()

        for item in items {
            let base = sanitize(item.name)
            var candidate = base
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base) \(suffix)"
                suffix += 1
            }
            names[item.id] = candidate
            used.insert(candidate.lowercased())
        }

        return names
    }

    /// Filenames to delete in an orphan sweep. A bundle is an orphan when it
    /// carries a `DockPopsTargetPopID` that is **not** among the current Pops.
    /// Keyless/foreign bundles (no embedded UUID) and hidden/temp staging
    /// bundles (leading dot) are never touched — keyed on the embedded UUID,
    /// not the filename, so it is dual-scheme-safe.
    static func orphanFilenames(
        onDisk: [(filename: String, targetPopID: UUID?)],
        currentPopIDs: Set<UUID>
    ) -> [String] {
        onDisk.compactMap { entry in
            guard !entry.filename.hasPrefix(".") else { return nil }
            guard entry.filename.hasSuffix(".app") else { return nil }
            guard let id = entry.targetPopID else { return nil }
            return currentPopIDs.contains(id) ? nil : entry.filename
        }
    }
}
