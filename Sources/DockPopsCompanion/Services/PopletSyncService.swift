import AppKit
import Foundation
import PopletKit
import os

/// Not `@MainActor`: `sync()` is file-I/O heavy (it drives `PopletKit.sync` —
/// bundle writes, signing, `lsregister` — plus the icon mirror) and must run off
/// the main actor or it beach-balls the launch. The class is effectively
/// immutable (all stored properties are `let`) and `refreshNow()` serializes
/// calls, so `@unchecked Sendable` is sound. `requestSharedContainerAccess()`
/// keeps its own `@MainActor` — it shows UI.
///
/// The poplet *lifecycle* (rename + registry + bundle generation) lives in
/// PopletKit now; this service is the Companion-side seam: bookmark access, the
/// non-gated icon mirror, mapping Pops → `PopletSpec`, and assembling the UI
/// snapshot. See `docs/specs/migrate-companion-to-poplet-kit.md`.
final class PopletSyncService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.dockpops.companion", category: "PopletSync")

    private let fileManager = FileManager.default
    private let popStore = SharedPopStore()
    private let popletExecutableName = "DockPopsPoplet"

    func hasStoredSharedContainerBookmark() -> Bool {
        SharedContainerAccess.hasStoredBookmark()
    }

    @MainActor
    func requestSharedContainerAccess() throws {
        _ = try SharedContainerAccess.requestAccess()
    }

    func startupSnapshot() -> SyncSnapshot {
        let dockPopsFound = dockPopsApplicationURL() != nil
        return SyncSnapshot(
            pops: [],
            poplets: [],
            stats: .zero,
            hasSharedContainerAccess: false,
            hasStoredSharedContainerBookmark: hasStoredSharedContainerBookmark(),
            metadataAvailable: false,
            dockPopsFound: dockPopsFound,
            errorDescription: nil
        )
    }

    func sync() -> SyncSnapshot {
        let dockPopsFound = dockPopsApplicationURL() != nil
        let hasStoredBookmark = hasStoredSharedContainerBookmark()

        guard dockPopsFound else {
            return SyncSnapshot(
                pops: [],
                poplets: [],
                stats: .zero,
                hasSharedContainerAccess: false,
                hasStoredSharedContainerBookmark: hasStoredBookmark,
                metadataAvailable: false,
                dockPopsFound: dockPopsFound,
                errorDescription: nil
            )
        }

        guard hasStoredBookmark else {
            return SyncSnapshot(
                pops: [],
                poplets: [],
                stats: .zero,
                hasSharedContainerAccess: false,
                hasStoredSharedContainerBookmark: false,
                metadataAvailable: false,
                dockPopsFound: dockPopsFound,
                errorDescription: nil
            )
        }

        do {
            try ensureDirectory(AppPaths.popletsDirectoryURL)
            try ensureDirectory(AppPaths.companionSupportDirectoryURL)
            try ensureDirectory(AppPaths.popletLiveIconsDirectoryURL)
            try ensureDirectory(AppPaths.iconsDirectoryURL)
            return try SharedContainerAccess.withAccess { containerURL in
                let paths = SharedContainerPaths(containerURL: containerURL)
                try ensureSharedContainerAccess(at: paths.containerURL)
                // Companion-internal mirror (Application Support) — the running
                // Poplet's file-watcher source (non-gated, defense-in-depth).
                try PopletLiveIconMirror.sync(
                    sourceDirectoryURL: paths.sharedPopIconsDirectoryURL,
                    fileManager: fileManager
                )
                // TCC fix: the load-bearing non-gated read surface. The ad-hoc
                // Poplet reads `~/Applications/DockPops/Icons/<uuid>.png` +
                // `<uuid>.live.png` from here (never the App Group container, a
                // read of which prompts on every click). Verbatim byte-copies →
                // byte-identity holds; orphan sweep removes deleted Pops' icons.
                try PopletLiveIconMirror.sync(
                    sourceDirectoryURL: paths.sharedPopIconsDirectoryURL,
                    destinationDirectoryURL: AppPaths.iconsDirectoryURL,
                    fileManager: fileManager
                )

                let metadataAvailable = fileManager.fileExists(atPath: paths.shortcutGroupsURL.path)

                guard metadataAvailable else {
                    return SyncSnapshot(
                        pops: [],
                        poplets: loadExistingPoplets(paths: paths),
                        stats: .zero,
                        hasSharedContainerAccess: true,
                        hasStoredSharedContainerBookmark: true,
                        metadataAvailable: false,
                        dockPopsFound: dockPopsFound,
                        errorDescription: nil
                    )
                }

                let pops = try popStore.loadPops(from: paths.shortcutGroupsURL)
                let result = try syncPoplets(for: pops, paths: paths)
                return SyncSnapshot(
                    pops: pops,
                    poplets: result.poplets,
                    stats: result.stats,
                    hasSharedContainerAccess: true,
                    hasStoredSharedContainerBookmark: true,
                    metadataAvailable: true,
                    dockPopsFound: dockPopsFound,
                    errorDescription: nil,
                    renameFailed: result.renameFailed
                )
            }
        } catch let error as SharedContainerAccessError {
            let message = error == .permissionRequired || error == .userCancelled
                ? nil
                : error.localizedDescription

            return SyncSnapshot(
                pops: [],
                poplets: [],
                stats: .zero,
                hasSharedContainerAccess: false,
                hasStoredSharedContainerBookmark: hasStoredSharedContainerBookmark(),
                metadataAvailable: false,
                dockPopsFound: dockPopsFound,
                errorDescription: message
            )
        } catch {
            Self.logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
            return SyncSnapshot(
                pops: [],
                poplets: [],
                stats: .zero,
                hasSharedContainerAccess: false,
                hasStoredSharedContainerBookmark: hasStoredBookmark,
                metadataAvailable: false,
                dockPopsFound: dockPopsFound,
                errorDescription: error.localizedDescription
            )
        }
    }

    private func syncPoplets(for pops: [PopRecord], paths: SharedContainerPaths) throws -> (stats: SyncStats, poplets: [PopletStatus], renameFailed: Bool) {
        guard let popletExecutableSource = bundledPopletExecutableURL() else {
            throw NSError(
                domain: "DockPopsCompanion",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bundled DockPops poplet executable not found."]
            )
        }

        // PopletKit owns the lifecycle (rename + registry + bundle generation).
        // The Companion supplies the per-channel environment + the desired specs
        // and keeps everything else (icon resolution, the Icons/ mirror, the
        // bookmark, the snapshot, the poplet runtime).
        let environment = PopletKit.PopletEnvironment(
            popletsDirectory: AppPaths.popletsDirectoryURL,
            registryURL: AppPaths.popletRegistryURL,
            popletExecutableSource: popletExecutableSource,
            popletExecutableName: popletExecutableName,
            appShortVersion: currentCompanionShortVersionString(),
            appBuildVersion: currentCompanionBuildVersion()
        )

        // Render the DockPops-app-icon fallback once (for any Pop lacking a
        // composite); reused across icon-less specs, cleaned up after sync.
        let fallbackIconURL = dockPopsAppIconFallbackURL()
        defer { if let fallbackIconURL { try? fileManager.removeItem(at: fallbackIconURL) } }

        // Map Pops → specs. The composite is the on-disk URL the Companion
        // already resolves (container PNG, read by the kit inside this sync's
        // active bookmark scope) with the rendered DockPops-icon fallback.
        var iconSources: [UUID: PopletIconSource] = [:]
        let specs: [PopletKit.PopletSpec] = pops.map { pop in
            let resolved = resolvedCompositeIconURL(for: pop.id, paths: paths, fallbackURL: fallbackIconURL)
            iconSources[pop.id] = resolved.source
            return PopletKit.PopletSpec(
                id: pop.id,
                displayName: pop.name,
                compositeIconURL: resolved.url,
                iconSource: kitIconSource(resolved.source)
            )
        }

        // The kit's default terminator already matches the unified
        // `com.dockpops.poplet.` bundle id, so we don't inject our own.
        let kitStats = PopletKit.sync(specs: specs, in: environment, fileManager: fileManager)
        var stats = SyncStats.zero
        stats.created = kitStats.created
        stats.updated = kitStats.updated
        stats.renamed = kitStats.renamed
        stats.removed = kitStats.removed

        // Rebuild the UI list from the kit's resolver (the kit wrote the registry
        // + moved the bundles). `iconSource` is the Companion's own UI concept,
        // carried from the spec resolution above.
        let poplets: [PopletStatus] = pops.compactMap { pop in
            guard let url = PopletKit.currentBundleURL(for: pop.id, in: environment, fileManager: fileManager) else {
                return nil
            }
            return PopletStatus(
                popID: pop.id,
                popName: pop.name,
                popletURL: url,
                iconSource: iconSources[pop.id] ?? .generic
            )
        }
        .sorted { $0.popName.localizedCaseInsensitiveCompare($1.popName) == .orderedAscending }

        // MAS DockPops bridge: mirror the kit-written registry into the shared
        // App Group container (the "Companion has synced" gate the MAS app reads;
        // it resolves Poplets by enumerating ~/Applications/DockPops directly,
        // not by parsing this file). Best-effort + idempotent. Requires the
        // com.apple.security.application-groups entitlement on this target.
        if let groupURL = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: "group.com.dockpops.shared"),
           let registryData = try? Data(contentsOf: AppPaths.popletRegistryURL) {
            let mirrorURL = groupURL.appending(path: "poplet-registry.json")
            if (try? Data(contentsOf: mirrorURL)) != registryData {
                do {
                    try registryData.write(to: mirrorURL, options: .atomic)
                } catch {
                    Self.logger.warning("MAS bridge mirror write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        return (stats, poplets, kitStats.renameFailed)
    }

    private func loadExistingPoplets(paths: SharedContainerPaths) -> [PopletStatus] {
        let registry = (try? loadRegistry(from: AppPaths.popletRegistryURL)) ?? [:]
        return registry.compactMap { uuidString, entry in
            guard let uuid = UUID(uuidString: uuidString) else { return nil }
            let popletURL = popletBundleURL(filename: entry.filename)
            guard fileManager.fileExists(atPath: popletURL.path) else { return nil }
            return PopletStatus(
                popID: uuid,
                popName: entry.displayName,
                popletURL: popletURL,
                iconSource: inferredIconSource(for: uuid, paths: paths)
            )
        }
        .sorted { $0.popName.localizedCaseInsensitiveCompare($1.popName) == .orderedAscending }
    }

    private func ensureSharedContainerAccess(at url: URL) throws {
        _ = try url.resourceValues(forKeys: [.isDirectoryKey])
    }

    /// Bundle URL for an explicit on-disk filename (already includes `.app`).
    /// The filename is the name-tracking `<resolvedName>.app` (moved on rename
    /// by PopletKit).
    private func popletBundleURL(filename: String) -> URL {
        AppPaths.popletsDirectoryURL.appending(path: filename, directoryHint: .isDirectory)
    }

    private func inferredIconSource(for popID: UUID, paths: SharedContainerPaths) -> PopletIconSource {
        let popIconURL = paths.sharedPopIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
        if fileManager.fileExists(atPath: popIconURL.path) {
            return .popComposite
        }
        return dockPopsApplicationURL() == nil ? .generic : .dockPopsApp
    }

    // MARK: - PopletKit seam (icon → composite URL)

    /// The composite icon as a file URL for PopletKit (which bakes the bundle
    /// icon from it). `popComposite` → the container PNG the Companion already
    /// reads (under the sync's active bookmark scope); `dockPopsApp` → the
    /// pre-rendered fallback PNG; `generic` → nil (kit ships no custom icon).
    private func resolvedCompositeIconURL(
        for popID: UUID, paths: SharedContainerPaths, fallbackURL: URL?
    ) -> (url: URL?, source: PopletIconSource) {
        let popIconURL = paths.sharedPopIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
        if fileManager.fileExists(atPath: popIconURL.path) {
            return (popIconURL, .popComposite)
        }
        if let fallbackURL {
            return (fallbackURL, .dockPopsApp)
        }
        return (nil, .generic)
    }

    /// Renders the DockPops app icon to a temp PNG so an icon-less Pop falls back
    /// to the DockPops icon (today's behavior). nil if DockPops isn't installed
    /// or the render fails. The caller cleans up the temp after sync.
    private func dockPopsAppIconFallbackURL() -> URL? {
        guard let appURL = dockPopsApplicationURL() else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        guard let data = icon.pngRepresentation else { return nil }
        let url = fileManager.temporaryDirectory
            .appending(path: "DockPopsFallbackIcon-\(UUID().uuidString).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Bridges the Companion's `PopletIconSource` to PopletKit's (same cases,
    /// different module).
    private func kitIconSource(_ source: PopletIconSource) -> PopletKit.PopletIconSource {
        switch source {
        case .popComposite: return .popComposite
        case .dockPopsApp: return .dockPopsApp
        case .generic: return .generic
        }
    }

    private func dockPopsApplicationURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppPaths.dockPopsBundleIdentifier)
    }

    /// Reads the registry PopletKit wrote (for the metadata-unavailable poplet
    /// list). The registry model + decode now live in PopletKit.
    private func loadRegistry(from url: URL) throws -> PopletKit.PopletRegistry.Map {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        return try PopletKit.PopletRegistry.decode(data)
    }

    private func ensureDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func bundledPopletExecutableURL() -> URL? {
        let helper = Bundle.main.bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Helpers", directoryHint: .isDirectory)
            .appending(path: popletExecutableName)
        if fileManager.fileExists(atPath: helper.path) {
            return helper
        }

        let legacy = Bundle.main.resourceURL?
            .appending(path: "PopletSupport", directoryHint: .isDirectory)
            .appending(path: popletExecutableName)
        if let legacy, fileManager.fileExists(atPath: legacy.path) {
            return legacy
        }
        return nil
    }

    private func currentCompanionShortVersionString() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    private func currentCompanionBuildVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }
}

/// SACRED CODE:
/// The companion is the only process that should ever touch DockPops'
/// protected `group.com.dockpops.shared` container for live per-Pop icon data
/// (it holds the security-scoped bookmark). It mirrors that data into NON-GATED
/// copies that the ad-hoc Poplet binary reads:
///   • `~/Applications/DockPops/Icons/` — load-bearing TCC-fix surface; the
///     Poplet reads `<uuid>.png` (healer) + `<uuid>.live.png` (live tile) here.
///   • `Application Support/DockPops Companion/PopletLiveIcons/` — the running
///     tile's file-watcher source (defense-in-depth).
///
/// If you are tempted to make a Poplet read `group.com.dockpops.shared`
/// directly, stop. An ad-hoc Poplet isn't a member of that App Group, so the
/// read trips the macOS 26 "data from other apps" prompt on every click — the
/// exact bug this mirror exists to avoid.
enum PopletLiveIconMirror {
    private static let mirrorFileExtension = "png"

    static func sync(
        sourceDirectoryURL: URL,
        destinationDirectoryURL: URL = AppPaths.popletLiveIconsDirectoryURL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: destinationDirectoryURL, withIntermediateDirectories: true)

        let sourceFileURLs: [URL]
        if fileManager.fileExists(atPath: sourceDirectoryURL.path) {
            sourceFileURLs = try fileManager.contentsOfDirectory(
                at: sourceDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter {
                $0.pathExtension.caseInsensitiveCompare(mirrorFileExtension) == .orderedSame
            }
        } else {
            sourceFileURLs = []
        }

        let destinationFileURLs = (try? fileManager.contentsOfDirectory(
            at: destinationDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let desiredFilenames = Set(sourceFileURLs.map(\.lastPathComponent))

        for sourceFileURL in sourceFileURLs {
            let destinationFileURL = destinationDirectoryURL.appending(path: sourceFileURL.lastPathComponent)
            let sourceData = try Data(contentsOf: sourceFileURL)

            if
                fileManager.fileExists(atPath: destinationFileURL.path),
                let existingData = try? Data(contentsOf: destinationFileURL),
                existingData == sourceData
            {
                continue
            }

            try sourceData.write(to: destinationFileURL, options: .atomic)
        }

        for destinationFileURL in destinationFileURLs
        where destinationFileURL.pathExtension.caseInsensitiveCompare(mirrorFileExtension) == .orderedSame
        {
            guard !desiredFilenames.contains(destinationFileURL.lastPathComponent) else { continue }
            try? fileManager.removeItem(at: destinationFileURL)
        }
    }
}
