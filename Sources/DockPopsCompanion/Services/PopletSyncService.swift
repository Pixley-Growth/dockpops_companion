import AppKit
import Darwin
import Foundation
import os

/// Not `@MainActor`: `sync()` is file-I/O heavy (poplet bundle writes, icon
/// healing, `lsregister`) and must run off the main actor or it beach-balls the
/// launch. The class is effectively immutable (all stored properties are `let`)
/// and `refreshNow()` serializes calls, so `@unchecked Sendable` is sound.
/// `requestSharedContainerAccess()` keeps its own `@MainActor` — it shows UI.
final class PopletSyncService: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.dockpops.companion", category: "PopletSync")
    private static let popletAppIconName = "AppIcon"
    /// Bump when the poplet icon rendering recipe changes even if the source
    /// PopIcons PNG does not. This forces unopened poplets onto a fresh bundle
    /// version so Dock/Finder stop serving stale cached icons.
    /// 12: bake .icns / Assets.car from the inset, rounded presentation canvas
    ///     instead of full-bleed PopIcons art.
    /// 13: inset tuned to 0.832 — macOS 26 renders generated Poplet icons as-is
    ///     (no Tahoe shrink), so the bake matches sibling apps at 83.2%.
    /// 14: poplet healer no longer aborts after stripping Finder custom icons
    ///     when actool fails to produce Assets.car; it falls back to ICNS-only
    ///     and reapplies the Finder custom icon.
    /// 15: in-place install + no-move-on-rename make it safe to force-
    ///     regenerate existing Poplets in place (same `.app` inode, so the Dock
    ///     pin survives). Bumping rebakes old "ugly Tahoe white-border" icons on
    ///     the next sync without breaking any pinned tile.
    /// 16: TCC fix + bundle-id unification. The bump forces a one-time in-place
    ///     regen of every existing Poplet so they (a) embed the new poplet
    ///     binary that reads icons from the non-gated `~/Applications/DockPops/
    ///     Icons/` folder instead of the App Group container (stops the "data
    ///     from other apps" prompt), and (b) re-stamp + re-sign under the
    ///     unified `com.dockpops.poplet.<uuid>` id (matches DockPops Complete).
    ///     In-place install preserves the `.app` inode, so Dock pins survive the
    ///     identity change.
    private static let popletIconRecipeVersion = 16
    private static let popletIconRecipeVersionInfoKey = "DockPopsIconRecipeVersion"
    private static let launchServicesRegisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"

    private let fileManager = FileManager.default
    private let popStore = SharedPopStore()
    private let popletExecutableName = "DockPopsPoplet"

    /// Clears the resident Poplet's "item is open" lock before an in-place
    /// inode-preserving rename (Fix B). Injected so the rename path is testable.
    private let terminator: PopletTerminating

    init(terminator: PopletTerminating = RunningApplicationPopletTerminator()) {
        self.terminator = terminator
    }

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
        let previousRegistry = try loadRegistry(from: AppPaths.popletRegistryURL)

        // Collision-free display names in stable Pop order: the FIRST Pop named
        // "Work" keeps the bare `Work.app` (what the unchanged MAS reader looks
        // for); a second same-named Pop gets `Work 2.app`. Drives BOTH the
        // on-disk filename (the Dock label) AND CFBundleDisplayName/CFBundleName.
        let desiredNames = PopletRegistry.resolvedDisplayNames(
            for: pops.map { (id: $0.id, name: $0.name) },
            sanitize: sanitizedPopletName
        )

        // ── Swap/cycle-safe rename batch (Fix B) ─────────────────────────────
        // The Dock labels a pinned tile from the `.app` FILENAME, so a Pop
        // rename must move the bundle to `<newName>.app` inode-preservingly (the
        // pin's bookmark follows). We reconcile ALL Pops in one launch pass, so
        // a name *swap* (A→"Home", B→"Work") would deadlock a naïve per-bundle
        // loop; `planRenames` orders the batch (cycles broken via a temp hop)
        // and `executeRenamePlan` terminates each resident Poplet then renames,
        // classifying any occupant by its embedded DockPopsTargetPopID. (Copied
        // verbatim from DockPops Complete — PopletRenameCore.)
        var renameRequests: [PopletRenameCore.PopletRenamePlan] = []
        var originalFrom: [UUID: String] = [:]
        for pop in pops {
            guard let name = desiredNames[pop.id] else { continue }
            let desiredFilename = "\(name).app"
            if case .rename(let from) = PopletRenameCore.renameAction(
                existingFilename: previousRegistry[pop.id.uuidString]?.filename,
                desiredFilename: desiredFilename
            ) {
                renameRequests.append(.init(popID: pop.id, from: from, to: desiredFilename))
                originalFrom[pop.id] = from
            }
        }
        let renameOutcomes = PopletRenameCore.executeRenamePlan(
            PopletRenameCore.planRenames(renameRequests),
            originalFrom: originalFrom,
            directory: AppPaths.popletsDirectoryURL,
            terminator: terminator,
            fileManager: fileManager
        )

        var nextRegistry: PopletRegistry.Map = [:]
        var poplets: [PopletStatus] = []
        var stats = SyncStats.zero
        var renameFailed = false

        for pop in pops {
            guard let displayName = desiredNames[pop.id] else { continue }
            let desiredFilename = "\(displayName).app"
            let previousEntry = previousRegistry[pop.id.uuidString]

            // Resolve the filename this Pop's bundle actually ends at, consuming
            // the rename batch outcome. A brand-new Pop / vanished source picks
            // an occupant-safe name via freshWriteFilename so it never clobbers
            // a foreign `.app`. On a real failure we keep the rolled-back
            // (still-pinned) name and flag the recovery banner.
            let filename: String
            switch PopletRenameCore.renameAction(
                existingFilename: previousEntry?.filename,
                desiredFilename: desiredFilename
            ) {
            case .keep:
                filename = desiredFilename
            case .create:
                filename = PopletRenameCore.freshWriteFilename(
                    desired: desiredFilename, popID: pop.id,
                    directory: AppPaths.popletsDirectoryURL, fileManager: fileManager
                )
            case .rename:
                switch renameOutcomes[pop.id] {
                case .renamed(let name): filename = name
                case .deferred(let name): filename = name
                case .failed(let name): filename = name; renameFailed = true
                case .recreate, .none:
                    filename = PopletRenameCore.freshWriteFilename(
                        desired: desiredFilename, popID: pop.id,
                        directory: AppPaths.popletsDirectoryURL, fileManager: fileManager
                    )
                }
            }

            let popletURL = popletBundleURL(filename: filename)
            // Regen-clobber guard: existence is keyed on the bundle now on disk
            // at the resolved (post-rename) filename, which the registry below
            // is set to — so a renamed bundle never reads as "missing".
            let hadExistingBundle = previousEntry != nil && fileManager.fileExists(atPath: popletURL.path)

            // The on-disk rename (if any) already moved the directory; this
            // writes/relabels the bundle (CFBundleDisplayName/CFBundleName) in
            // place when the icon/version/name changed.
            let iconSource = try writePopletBundle(
                for: pop,
                filename: filename,
                displayName: displayName,
                paths: paths
            )

            if !hadExistingBundle {
                stats.created += 1
            } else if previousEntry?.displayName != displayName {
                stats.renamed += 1
            } else {
                stats.updated += 1
            }

            nextRegistry[pop.id.uuidString] = PopletRegistryEntry(
                filename: filename,
                displayName: displayName
            )
            poplets.append(
                PopletStatus(
                    popID: pop.id,
                    popName: pop.name,
                    popletURL: popletURL,
                    iconSource: iconSource
                )
            )
        }

        stats.removed += try removeOrphanedPoplets(currentPopIDs: Set(pops.map(\.id)))
        try writeRegistry(nextRegistry, to: AppPaths.popletRegistryURL)
        // MAS DockPops bridge: mirror the registry to the shared App Group
        // container. The current MAS bridge (`CompanionPopletBridge`) only reads
        // this file's SIZE > 0 as a "Companion has synced at least once" gate —
        // it resolves Poplets by enumerating ~/Applications/DockPops directly,
        // not by parsing this file. So we mirror in whatever shape the registry
        // already uses (no MAS-specific structure); the future resolve-by-UUID
        // MAS reader will read DockPopsTargetPopID from each bundle's Info.plist
        // (the single source of truth), not this mirror. Best-effort — a nil
        // container URL or write failure does not abort the sync. Requires the
        // com.apple.security.application-groups = ["group.com.dockpops.shared"]
        // entitlement on this target.
        if let groupURL = FileManager.default.containerURL(
               forSecurityApplicationGroupIdentifier: "group.com.dockpops.shared") {
            let mirrorURL = groupURL.appending(path: "poplet-registry.json")
            do {
                try writeRegistry(nextRegistry, to: mirrorURL)
            } catch {
                Self.logger.warning("MAS bridge mirror write failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let sortedPoplets = poplets.sorted {
            $0.popName.localizedCaseInsensitiveCompare($1.popName) == .orderedAscending
        }
        return (stats, sortedPoplets, renameFailed)
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

    private func sanitizedPopletName(_ rawName: String) -> String {
        let replaced = rawName.replacingOccurrences(
            of: #"[/:\\]+"#,
            with: "-",
            options: .regularExpression
        )
        let compactWhitespace = replaced.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        return compactWhitespace.trimmedOrNil ?? "Pop"
    }

    /// Bundle URL for an explicit on-disk filename (already includes `.app`).
    /// The filename is the name-tracking `<resolvedName>.app` (moved on rename
    /// by `PopletRenameCore`).
    private func popletBundleURL(filename: String) -> URL {
        AppPaths.popletsDirectoryURL.appending(path: filename, directoryHint: .isDirectory)
    }

    private func writePopletBundle(
        for pop: PopRecord,
        filename: String,
        displayName: String,
        paths: SharedContainerPaths
    ) throws -> PopletIconSource {
        let bundleURL = popletBundleURL(filename: filename)
        let stagingBundleURL = temporarySiblingURL(for: bundleURL, label: "staging")
        let contentsURL = stagingBundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        let macOSURL = contentsURL.appending(path: "MacOS", directoryHint: .isDirectory)
        let resourcesURL = contentsURL.appending(path: "Resources", directoryHint: .isDirectory)
        let appIconURL = resourcesURL.appending(path: "\(Self.popletAppIconName).icns")

        guard let bundledPopletURL = bundledPopletExecutableURL() else {
            throw NSError(
                domain: "DockPopsCompanion",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bundled DockPops poplet executable not found."]
            )
        }

        let resolvedIcon = resolvedPopletIcon(for: pop.id, paths: paths)

        // Skip the rebuild when the bundle on disk is already the desired
        // recipe + icon + label. Defense-in-depth: the user-visible
        // "Refreshing…" loop that originally surfaced this code path was driven
        // by a non-idempotent writeRegistry (now fixed). This guard remains
        // because an unconditional rebuild per sync still wastes work — reruns
        // codesign and rewrites the Finder custom icon. CFBundleVersion encodes
        // popletIconRecipeVersion + stableIconFingerprint (see
        // bundleVersionForDockPopsIcon / bundleVersionForPopComposite); the
        // displayName check catches a pure rename (same icon/version, new
        // label) so CFBundleDisplayName/CFBundleName still get rewritten in
        // place — otherwise a renamed Pop's tile would keep its old label.
        if existingBundleMatches(
            at: bundleURL,
            expectedVersion: resolvedIcon.bundleVersion,
            expectedDisplayName: displayName
        ) {
            return resolvedIcon.source
        }

        // SACRED CODE:
        // Bake the .icns / Assets.car from the NORMALIZED (inset) image —
        // never `resolvedIcon.image`, which is full-bleed PopIcons art.
        // Commit 48f9cad shipped the raw bake and the closed Dock tile
        // rendered ~15% oversized against every sibling icon. This regression
        // has recurred more than once; do not "simplify" the bake back to raw.
        let presentationIcon = resolvedIcon.image?.normalizedPopletAppIcon() ?? resolvedIcon.image
        return try withBundleLocks(for: [bundleURL]) {
            let executableURL = macOSURL.appending(path: popletExecutableName)
            let infoPlistURL = contentsURL.appending(path: "Info.plist")
            let pkgInfoURL = contentsURL.appending(path: "PkgInfo")
            let iconData = try generatedIconDataIfPossible(for: presentationIcon)
            // macOS 26 plate-free icon: compiled asset catalog + CFBundleIconName.
            // nil when actool is unavailable — the bundle falls back to .icns only.
            let assetCatalogData = generatedAssetCatalogDataIfPossible(for: presentationIcon)

            if fileManager.fileExists(atPath: stagingBundleURL.path) {
                try fileManager.removeItem(at: stagingBundleURL)
            }
            try ensureDirectory(stagingBundleURL)
            try ensureDirectory(contentsURL)
            try ensureDirectory(macOSURL)
            try ensureDirectory(resourcesURL)
            try removeLegacyCustomIconArtifacts(from: stagingBundleURL)

            try fileManager.copyItem(at: bundledPopletURL, to: executableURL)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
            stripCopiedLauncherSignatureIfPossible(at: executableURL)

            var plist: [String: Any] = [
                "CFBundleDevelopmentRegion": "en",
                // Display label = the Pop's CURRENT (resolved) name. The Dock
                // labels a PINNED tile from the `.app` filename (renamed on disk
                // by PopletRenameCore); these keys drive Finder + the non-pinned
                // label, so they track the live name and are rewritten in place.
                "CFBundleDisplayName": displayName,
                "CFBundleExecutable": popletExecutableName,
                // Unified poplet bundle id (matches DockPops Complete + the
                // shared-channel contract). Was `com.dockpops.companion.poplet.`;
                // the recipe-16 bump re-stamps existing bundles in place. Keep
                // in lockstep with PopletRenameCore.popletBundleIDPrefix (the
                // terminate-on-rename lookup) and the Poplet's own runtime.
                "CFBundleIdentifier": "com.dockpops.poplet.\(pop.id.uuidString.lowercased())",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": displayName,
                "CFBundlePackageType": "APPL",
                "CFBundleShortVersionString": currentCompanionShortVersionString(),
                "CFBundleSupportedPlatforms": ["MacOSX"],
                "CFBundleVersion": resolvedIcon.bundleVersion,
                "CFBundleDocumentTypes": Self.popletDocumentTypes,
                "LSMinimumSystemVersion": "14.0",
                // SACRED CODE:
                // A Poplet exists only to relay a click to DockPops. LSUIElement
                // keeps it out of CMD+TAB and the menu bar from the instant
                // Launch Services reads the bundle — no runtime race with
                // NSApplication.setActivationPolicy(.accessory). Removing it
                // reintroduces the #1 user complaint. Keep it in lockstep with
                // the `.accessory` policy in DockPopsPopletMain.main().
                "LSUIElement": true,
                "NSPrincipalClass": "NSApplication",
                Self.popletIconRecipeVersionInfoKey: Self.popletIconRecipeVersion,
                "DockPopsTargetPopID": pop.id.uuidString,
            ]
            if iconData != nil {
                plist["CFBundleIconFile"] = Self.popletAppIconName
            }
            if assetCatalogData != nil {
                plist["CFBundleIconName"] = Self.popletAppIconName
            }
            let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try plistData.write(to: infoPlistURL, options: .atomic)
            try Data("APPL????".utf8).write(to: pkgInfoURL, options: .atomic)

            if let iconData {
                try iconData.write(to: appIconURL, options: .atomic)
            }
            if let assetCatalogData {
                try assetCatalogData.write(
                    to: resourcesURL.appending(path: "Assets.car"),
                    options: .atomic
                )
            }

            // Install BEFORE signing so we sign the final destination bundle in
            // place (§3.2). When the destination already exists, the install
            // syncs the staged Contents/ into the existing `.app` directory
            // without swapping the top-level directory — preserving its inode so
            // the Dock pin survives. Strip any stale Finder custom-icon metadata
            // (resource fork / FinderInfo) the previous bake left on the
            // destination before signing, because codesign rejects it; the icon
            // is reapplied after signing below.
            try installGeneratedPopletBundle(at: stagingBundleURL, destinationURL: bundleURL)
            try removeLegacyCustomIconArtifacts(from: bundleURL)
            try signGeneratedPopletBundle(at: bundleURL)
            applyFinderCustomIconIfPossible(resolvedIcon.image, to: bundleURL)
            refreshWorkspaceViews(for: bundleURL)
            return resolvedIcon.source
        }
    }

    // Allows Launch Services to route Finder Dock drops to the poplet app. The
    // poplet then hands those URLs to DockPops for ingestion into its target Pop.
    // `nonisolated(unsafe)`: an immutable plist constant the compiler cannot
    // prove `Sendable` through `[String: Any]`; it is never mutated.
    private nonisolated(unsafe) static let popletDocumentTypes: [[String: Any]] = [
        [
            "CFBundleTypeName": "Application",
            "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": ["com.apple.application-bundle"],
        ],
        [
            "CFBundleTypeName": "File or Folder",
            "CFBundleTypeRole": "Viewer",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": ["public.item"],
        ],
    ]

    private func resolvedPopletIcon(for popID: UUID, paths: SharedContainerPaths) -> ResolvedPopletIcon {
        let baseBuildVersion = currentCompanionBuildVersion()
        let popIconURL = paths.sharedPopIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
        if let image = NSImage(contentsOf: popIconURL) {
            // The shared PopIcons PNG is full-bleed composed art. Return it raw
            // here; writePopletBundle insets it onto the standard app-icon
            // presentation canvas before baking (do NOT bake it full-bleed —
            // that makes the closed Dock tile oversized). Generated bundles also
            // get a Finder custom icon after signing to defeat the Tahoe plate.
            return ResolvedPopletIcon(
                image: image,
                source: .popComposite,
                bundleVersion: bundleVersionForPopComposite(at: popIconURL, baseBuildVersion: baseBuildVersion)
            )
        }

        if let dockPopsIcon = resolvedDockPopsIcon(baseBuildVersion: baseBuildVersion) {
            return ResolvedPopletIcon(
                image: dockPopsIcon.image,
                source: .dockPopsApp,
                bundleVersion: dockPopsIcon.bundleVersion
            )
        }

        return ResolvedPopletIcon(image: nil, source: .generic, bundleVersion: baseBuildVersion)
    }

    private func inferredIconSource(for popID: UUID, paths: SharedContainerPaths) -> PopletIconSource {
        let popIconURL = paths.sharedPopIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
        if fileManager.fileExists(atPath: popIconURL.path) {
            return .popComposite
        }
        return dockPopsApplicationURL() == nil ? .generic : .dockPopsApp
    }

    private func resolvedDockPopsIcon(baseBuildVersion: String) -> ResolvedDockPopsIcon? {
        guard let appURL = dockPopsApplicationURL() else { return nil }
        let rawImage = NSWorkspace.shared.icon(forFile: appURL.path)
        return ResolvedDockPopsIcon(
            image: rawImage,
            bundleVersion: bundleVersionForDockPopsIcon(image: rawImage, baseBuildVersion: baseBuildVersion)
        )
    }

    private func dockPopsApplicationURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppPaths.dockPopsBundleIdentifier)
    }

    private func loadRegistry(from url: URL) throws -> PopletRegistry.Map {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        return try PopletRegistry.decode(data)
    }

    private func writeRegistry(_ registry: PopletRegistry.Map, to url: URL) throws {
        // Idempotent: PopletRegistry.encode emits sorted JSON, and the
        // content-compare keeps the bytes stable across syncs so writes into
        // the App Group container don't re-trigger SharedContainerWatcher and
        // loop the sync.
        let data = try PopletRegistry.encode(registry)
        if
            fileManager.fileExists(atPath: url.path),
            let existingData = try? Data(contentsOf: url),
            existingData == data
        {
            return
        }
        try data.write(to: url, options: .atomic)
    }

    /// Orphan sweep keyed on each bundle's embedded `DockPopsTargetPopID`
    /// (§3.7) rather than a registry name-diff, which proved unreliable. A
    /// directory sweep also reclaims historical orphans left by the old code.
    /// Dual-scheme-safe: keyed on the embedded UUID, never the filename (which
    /// now tracks the Pop name and moves on rename).
    private func removeOrphanedPoplets(currentPopIDs: Set<UUID>) throws -> Int {
        let directoryURL = AppPaths.popletsDirectoryURL
        guard fileManager.fileExists(atPath: directoryURL.path) else { return 0 }

        let entries = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        // Pure selection (testable). Foreign/keyless bundles and hidden/temp
        // staging bundles are excluded; only bundles whose embedded UUID is not
        // a current Pop are returned.
        let onDisk = entries.map { url in
            (filename: url.lastPathComponent, targetPopID: embeddedTargetPopID(of: url))
        }
        let orphanFilenames = Set(
            PopletRegistry.orphanFilenames(onDisk: onDisk, currentPopIDs: currentPopIDs)
        )

        var removed = 0
        for url in entries where orphanFilenames.contains(url.lastPathComponent) {
            try withBundleLocks(for: [url]) {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                    removed += 1
                }
            }
        }

        return removed
    }

    /// Reads `DockPopsTargetPopID` from a bundle's Info.plist, or nil for a
    /// foreign/keyless bundle (one the user dropped in, or a non-Poplet `.app`).
    private func embeddedTargetPopID(of bundleURL: URL) -> UUID? {
        let infoPlistURL = bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Info.plist")
        guard
            let data = try? Data(contentsOf: infoPlistURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any],
            let uuidString = plist["DockPopsTargetPopID"] as? String
        else {
            return nil
        }
        return UUID(uuidString: uuidString)
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

    /// The copied helper binary arrives pre-signed inside the Companion app bundle.
    /// Generated poplets get their own final bundle signature after we finish
    /// writing Info.plist and the icon resources, so strip the inherited launcher
    /// signature first to avoid mixing nested signing states.
    private func stripCopiedLauncherSignatureIfPossible(at executableURL: URL) {
        do {
            let result = try runProcess(
                executablePath: "/usr/bin/codesign",
                arguments: ["--remove-signature", executableURL.path]
            )
            if result.terminationStatus != 0 {
                let output = result.output.isEmpty ? "unknown error" : result.output
                Self.logger.error("signature strip failed for \(executableURL.lastPathComponent, privacy: .public): \(output, privacy: .public)")
            }
        } catch {
            Self.logger.error("Unable to strip signature for \(executableURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func generatedIconDataIfPossible(for image: NSImage?) throws -> Data? {
        guard let image else { return nil }

        let tempRootURL = AppPaths.companionSupportDirectoryURL
            .appending(path: "IconBuild", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let iconsetURL = tempRootURL.appending(path: "\(Self.popletAppIconName).iconset", directoryHint: .isDirectory)
        let icnsURL = tempRootURL.appending(path: "\(Self.popletAppIconName).icns")

        try ensureDirectory(iconsetURL)
        defer { try? fileManager.removeItem(at: tempRootURL) }

        let iconVariants: [(name: String, size: Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]

        for variant in iconVariants {
            guard let data = image.pngRepresentation(squarePixelSize: variant.size) else {
                throw NSError(
                    domain: "DockPopsCompanion",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to render \(variant.name) for generated poplet icon."]
                )
            }
            try data.write(to: iconsetURL.appending(path: variant.name), options: .atomic)
        }

        let result = try runProcess(
            executablePath: "/usr/bin/iconutil",
            arguments: ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
        )

        guard result.terminationStatus == 0 else {
            let output = result.output.isEmpty ? "unknown error" : result.output
            throw NSError(
                domain: "DockPopsCompanion",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "iconutil failed for generated poplet icon: \(output)"]
            )
        }

        return try Data(contentsOf: icnsURL)
    }

    /// Contents.json for the staged `AppIcon.appiconset`. Filenames match the
    /// variant PNGs written alongside it.
    private static let appIconAssetCatalogContentsJSON = """
    {
      "images" : [
        { "idiom" : "mac", "scale" : "1x", "size" : "16x16", "filename" : "icon_16x16.png" },
        { "idiom" : "mac", "scale" : "2x", "size" : "16x16", "filename" : "icon_16x16@2x.png" },
        { "idiom" : "mac", "scale" : "1x", "size" : "32x32", "filename" : "icon_32x32.png" },
        { "idiom" : "mac", "scale" : "2x", "size" : "32x32", "filename" : "icon_32x32@2x.png" },
        { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128x128.png" },
        { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128x128@2x.png" },
        { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256x256.png" },
        { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256x256@2x.png" },
        { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512x512.png" },
        { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512x512@2x.png" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }
    """

    /// Locates `actool` without triggering the Command Line Tools installer
    /// prompt that `xcrun` would raise on a machine with no developer tools.
    private func locateActool() -> URL? {
        guard
            let result = try? runProcess(executablePath: "/usr/bin/xcode-select", arguments: ["-p"]),
            result.terminationStatus == 0
        else {
            return nil
        }
        let developerDir = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !developerDir.isEmpty else { return nil }
        let actoolURL = URL(fileURLWithPath: developerDir)
            .appending(path: "usr", directoryHint: .isDirectory)
            .appending(path: "bin", directoryHint: .isDirectory)
            .appending(path: "actool")
        return fileManager.fileExists(atPath: actoolURL.path) ? actoolURL : nil
    }

    /// Compiles the Pop icon into an `Assets.car` asset catalog via `actool`.
    ///
    /// macOS 26 (Tahoe) draws a legacy `.icns`-only app icon inside a white
    /// system "plate". A compiled asset catalog plus `CFBundleIconName` makes
    /// Tahoe render the poplet edge-to-edge like a normal app icon.
    ///
    /// Returns `nil` when `actool` is unavailable (no Xcode / Command Line
    /// Tools) or fails — the caller then falls back to the `.icns`-only bundle,
    /// which works everywhere except for the Tahoe plate.
    private func generatedAssetCatalogDataIfPossible(for image: NSImage?) -> Data? {
        guard let image, let actoolURL = locateActool() else { return nil }

        let tempRootURL = AppPaths.companionSupportDirectoryURL
            .appending(path: "AssetCatalogBuild", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let catalogURL = tempRootURL.appending(path: "Assets.xcassets", directoryHint: .isDirectory)
        let iconSetURL = catalogURL.appending(path: "\(Self.popletAppIconName).appiconset", directoryHint: .isDirectory)
        let compileURL = tempRootURL.appending(path: "compiled", directoryHint: .isDirectory)
        let partialPlistURL = tempRootURL.appending(path: "partial-info.plist")

        let iconVariants: [(name: String, size: Int)] = [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ]

        do {
            try ensureDirectory(iconSetURL)
            try ensureDirectory(compileURL)
            defer { try? fileManager.removeItem(at: tempRootURL) }

            try Data(Self.appIconAssetCatalogContentsJSON.utf8)
                .write(to: iconSetURL.appending(path: "Contents.json"), options: .atomic)

            for variant in iconVariants {
                guard let data = image.pngRepresentation(squarePixelSize: variant.size) else {
                    return nil
                }
                try data.write(to: iconSetURL.appending(path: variant.name), options: .atomic)
            }

            let result = try runProcess(
                executablePath: actoolURL.path,
                arguments: [
                    catalogURL.path,
                    "--compile", compileURL.path,
                    "--platform", "macosx",
                    "--minimum-deployment-target", "14.0",
                    "--app-icon", Self.popletAppIconName,
                    "--output-partial-info-plist", partialPlistURL.path,
                    "--errors", "--warnings",
                ]
            )
            guard result.terminationStatus == 0 else {
                Self.logger.error("actool failed for poplet asset catalog: \(result.output, privacy: .public)")
                return nil
            }

            let compiledCatalogURL = compileURL.appending(path: "Assets.car")
            guard fileManager.fileExists(atPath: compiledCatalogURL.path) else {
                Self.logger.error("actool produced no Assets.car")
                return nil
            }
            return try Data(contentsOf: compiledCatalogURL)
        } catch {
            Self.logger.error("Unable to build poplet asset catalog: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func removeLegacyCustomIconArtifacts(from bundleURL: URL) throws {
        let iconFileURL = bundleURL.appending(path: "Icon\r")
        if fileManager.fileExists(atPath: iconFileURL.path) {
            try? fileManager.removeItem(at: iconFileURL)
        }

        let removalError: Int32 = bundleURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            if Darwin.removexattr(path, "com.apple.FinderInfo", 0) == 0 {
                return 0
            }
            return errno
        }

        if removalError != 0 && removalError != ENOATTR {
            let message = String(cString: strerror(removalError))
            Self.logger.error("Unable to clear Finder icon metadata for \(bundleURL.lastPathComponent, privacy: .public): \(message, privacy: .public)")
        }
    }

    private func applyFinderCustomIconIfPossible(_ image: NSImage?, to bundleURL: URL) {
        guard let image else { return }
        let presentationIcon = image.normalizedPopletAppIcon() ?? image

        // This intentionally runs after signing: Finder custom icons are stored
        // in resource-fork/FinderInfo metadata, which codesign rejects.
        guard NSWorkspace.shared.setIcon(presentationIcon, forFile: bundleURL.path, options: []) else {
            Self.logger.error(
                "Unable to apply Finder custom icon for \(bundleURL.lastPathComponent, privacy: .public)"
            )
            return
        }
        NSWorkspace.shared.noteFileSystemChanged(bundleURL.path)
    }

    private func signGeneratedPopletBundle(at bundleURL: URL) throws {
        // Poplet bundles are signed ad-hoc and WITHOUT entitlements. Click
        // events hand off to the Companion (which holds the trusted App Group
        // entitlement) via DistributedNotificationCenter — see
        // PopletOpenBridge + DockPopsPopletMain.postOpenPopViaCompanion. An
        // ad-hoc Poplet with an App Group entitlement prompts macOS 26 TCC
        // on every click ("...would like to access data from other apps").
        let result = try runProcess(
            executablePath: "/usr/bin/codesign",
            arguments: ["--force", "--deep", "--sign", "-", bundleURL.path]
        )

        guard result.terminationStatus == 0 else {
            let output = result.output.isEmpty ? "unknown error" : result.output
            throw NSError(
                domain: "DockPopsCompanion",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unable to sign generated poplet bundle: \(output)"]
            )
        }
    }

    /// Finder and Dock both cache bundle icons pretty aggressively. Once the
    /// regenerated poplet has a new AppIcon.icns on disk, nudge the workspace so
    /// visible surfaces have a chance to pick up the fresh icon immediately.
    private func refreshWorkspaceViews(for bundleURL: URL) {
        let resourcesURL = bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
        let iconURL = resourcesURL.appending(path: "\(Self.popletAppIconName).icns")
        NSWorkspace.shared.noteFileSystemChanged(iconURL.path)
        NSWorkspace.shared.noteFileSystemChanged(resourcesURL.path)
        NSWorkspace.shared.noteFileSystemChanged(bundleURL.path)
        NSWorkspace.shared.noteFileSystemChanged(AppPaths.popletsDirectoryURL.path)
        registerWithLaunchServices(bundleURL: bundleURL)
    }

    private func registerWithLaunchServices(bundleURL: URL) {
        do {
            let result = try runProcess(
                executablePath: Self.launchServicesRegisterPath,
                arguments: ["-f", bundleURL.path]
            )
            if result.terminationStatus != 0 {
                let output = result.output.isEmpty ? "unknown error" : result.output
                Self.logger.error("lsregister failed for \(bundleURL.lastPathComponent, privacy: .public): \(output, privacy: .public)")
            }
        } catch {
            Self.logger.error("Unable to refresh Launch Services for \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentCompanionShortVersionString() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    private func currentCompanionBuildVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "1"
    }

    private func bundleVersionForPopComposite(at url: URL, baseBuildVersion: String) -> String {
        let fallbackVersion = "\(baseBuildVersion).\(Self.popletIconRecipeVersion)"
        guard
            let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
            let modificationDate = resourceValues.contentModificationDate
        else {
            return fallbackVersion
        }

        let timestamp = max(1, Int(modificationDate.timeIntervalSince1970))
        return "\(baseBuildVersion).\(Self.popletIconRecipeVersion).\(timestamp)"
    }

    private func bundleVersionForDockPopsIcon(image: NSImage, baseBuildVersion: String) -> String {
        guard let pngData = image.pngRepresentation(squarePixelSize: 512) else {
            return "\(baseBuildVersion).\(Self.popletIconRecipeVersion)"
        }

        return "\(baseBuildVersion).\(Self.popletIconRecipeVersion).\(stableIconFingerprint(for: pngData))"
    }

    private func stableIconFingerprint(for data: Data) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in data {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return max(1, hash & 0x7fff_ffff)
    }

    private func existingBundleMatches(
        at bundleURL: URL,
        expectedVersion: String,
        expectedDisplayName: String
    ) -> Bool {
        let contentsURL = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        let infoPlistURL = contentsURL.appending(path: "Info.plist")
        let executableURL = contentsURL
            .appending(path: "MacOS", directoryHint: .isDirectory)
            .appending(path: popletExecutableName)

        guard fileManager.fileExists(atPath: executableURL.path) else { return false }
        guard let data = try? Data(contentsOf: infoPlistURL) else { return false }
        guard
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: Any]
        else { return false }
        guard let currentVersion = plist["CFBundleVersion"] as? String,
              currentVersion == expectedVersion
        else { return false }
        guard let currentRecipeVersion = plist[Self.popletIconRecipeVersionInfoKey] as? Int,
              currentRecipeVersion == Self.popletIconRecipeVersion
        else { return false }
        // Catch a pure rename: same icon/version but a new label must still
        // rewrite the bundle in place to update CFBundleDisplayName/CFBundleName.
        guard let currentDisplayName = plist["CFBundleName"] as? String,
              currentDisplayName == expectedDisplayName
        else { return false }
        return true
    }

    /// Installs the staged bundle at `destinationURL`.
    ///
    /// First creation moves staging → destination. When the destination
    /// already exists, the staged `Contents/` is synced **into** the existing
    /// `.app` directory (inner files replaced, stale ones removed) WITHOUT
    /// swapping the top-level directory — so the `.app` keeps its inode and the
    /// Dock pin survives (§3.2). Avoids `replaceItemAt`, which gives the
    /// destination a new inode and can break the pin even without a rename.
    private func installGeneratedPopletBundle(at stagingURL: URL, destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            try DirectoryInPlaceSync.sync(from: stagingURL, to: destinationURL, fileManager: fileManager)
            try? fileManager.removeItem(at: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    private func temporarySiblingURL(for bundleURL: URL, label: String) -> URL {
        bundleURL.deletingLastPathComponent().appending(
            path: ".\(bundleURL.deletingPathExtension().lastPathComponent).\(label).\(UUID().uuidString).app",
            directoryHint: .isDirectory
        )
    }

    private func withBundleLocks<Result>(
        for bundleURLs: [URL],
        body: () throws -> Result
    ) throws -> Result {
        let lockHandles = try bundleURLs
            .map(\.standardizedFileURL)
            .reduce(into: [URL: BundleLockHandle]()) { result, bundleURL in
                let lockURL = bundleLockURL(for: bundleURL)
                if result[lockURL] == nil {
                    result[lockURL] = try BundleLockHandle(lockURL: lockURL)
                }
            }
            .sorted { $0.key.path < $1.key.path }
            .map(\.value)

        defer {
            lockHandles.reversed().forEach { $0.unlock() }
        }
        return try body()
    }

    private func bundleLockURL(for bundleURL: URL) -> URL {
        bundleURL.deletingLastPathComponent().appending(path: ".\(bundleURL.lastPathComponent).lock")
    }

    private func runProcess(
        executablePath: String,
        arguments: [String]
    ) throws -> ProcessExecutionResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        let handle = pipe.fileHandleForReading
        let collector = ProcessOutputCollector()
        process.standardError = pipe
        process.standardOutput = pipe

        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            collector.append(chunk)
        }
        defer {
            handle.readabilityHandler = nil
        }

        try process.run()
        process.waitUntilExit()
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty {
            collector.append(remaining)
        }

        return ProcessExecutionResult(
            terminationStatus: process.terminationStatus,
            output: collector.stringValue
        )
    }
}

private struct ProcessExecutionResult {
    let terminationStatus: Int32
    let output: String
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct ResolvedPopletIcon {
    let image: NSImage?
    let source: PopletIconSource
    let bundleVersion: String
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

private struct ResolvedDockPopsIcon {
    let image: NSImage
    let bundleVersion: String
}

private final class BundleLockHandle {
    private let fileDescriptor: Int32
    private var isUnlocked = false

    init(lockURL: URL) throws {
        let path = lockURL.path
        let fileDescriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard flock(fileDescriptor, LOCK_EX) == 0 else {
            let lockError = errno
            close(fileDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }

        self.fileDescriptor = fileDescriptor
    }

    func unlock() {
        guard !isUnlocked else { return }
        isUnlocked = true
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    deinit {
        unlock()
    }
}
