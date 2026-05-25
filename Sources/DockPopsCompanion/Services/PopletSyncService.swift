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
    private static let popletIconRecipeVersion = 14
    private static let popletIconRecipeVersionInfoKey = "DockPopsIconRecipeVersion"
    private static let launchServicesRegisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"

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
            return try SharedContainerAccess.withAccess { containerURL in
                let paths = SharedContainerPaths(containerURL: containerURL)
                try ensureSharedContainerAccess(at: paths.containerURL)
                try PopletLiveIconMirror.sync(
                    sourceDirectoryURL: paths.sharedPopIconsDirectoryURL,
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
                    errorDescription: nil
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

    private func syncPoplets(for pops: [PopRecord], paths: SharedContainerPaths) throws -> (stats: SyncStats, poplets: [PopletStatus]) {
        let previousRegistry = try loadRegistry(from: AppPaths.popletRegistryURL)
        let previousNameByID: [UUID: String] = Dictionary(
            uniqueKeysWithValues: previousRegistry.compactMap { entry in
                guard let uuid = UUID(uuidString: entry.value) else { return nil }
                return (uuid, entry.key)
            }
        )

        let desiredNames = resolvedNames(for: pops)
        var nextRegistry: [String: String] = [:]
        var poplets: [PopletStatus] = []
        var stats = SyncStats.zero

        for pop in pops {
            guard let desiredName = desiredNames[pop.id] else { continue }
            let popletURL = popletBundleURL(named: desiredName)
            let oldName = previousNameByID[pop.id]
            let hadExistingBundle = oldName.map { fileManager.fileExists(atPath: popletBundleURL(named: $0).path) } ?? fileManager.fileExists(atPath: popletURL.path)

            if let oldName, oldName != desiredName {
                let didMove = try movePopletIfNeeded(from: oldName, to: desiredName)
                if didMove {
                    stats.renamed += 1
                }
            }

            let iconSource = try writePopletBundle(
                for: pop,
                popletName: desiredName,
                paths: paths
            )

            if oldName == desiredName || oldName == nil {
                if hadExistingBundle {
                    stats.updated += 1
                } else {
                    stats.created += 1
                }
            }

            nextRegistry[desiredName] = pop.id.uuidString
            poplets.append(
                PopletStatus(
                    popID: pop.id,
                    popName: pop.name,
                    popletURL: popletURL,
                    iconSource: iconSource
                )
            )
        }

        stats.removed += try removeOrphanedPoplets(previousRegistry: previousRegistry, desiredRegistry: nextRegistry)
        try writeRegistry(nextRegistry, to: AppPaths.popletRegistryURL)
        // MAS DockPops bridge (spec b' from main repo, 2026-05-25): mirror the
        // registry to the shared App Group container so MAS can offer the same
        // drag-to-Dock UX Complete users have. The mirror is best-effort — a
        // nil container URL or write failure does not abort the sync, it just
        // leaves MAS without the bridge data this cycle (next successful sync
        // rewrites). Requires the com.apple.security.application-groups
        // entitlement = ["group.com.dockpops.shared"] on this target.
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
        return (stats, sortedPoplets)
    }

    private func loadExistingPoplets(paths: SharedContainerPaths) -> [PopletStatus] {
        let registry = (try? loadRegistry(from: AppPaths.popletRegistryURL)) ?? [:]
        return registry.compactMap { name, uuidString in
            guard let uuid = UUID(uuidString: uuidString) else { return nil }
            let popletURL = popletBundleURL(named: name)
            guard fileManager.fileExists(atPath: popletURL.path) else { return nil }
            return PopletStatus(
                popID: uuid,
                popName: name,
                popletURL: popletURL,
                iconSource: inferredIconSource(for: uuid, paths: paths)
            )
        }
        .sorted { $0.popName.localizedCaseInsensitiveCompare($1.popName) == .orderedAscending }
    }

    private func ensureSharedContainerAccess(at url: URL) throws {
        _ = try url.resourceValues(forKeys: [.isDirectoryKey])
    }

    private func resolvedNames(for pops: [PopRecord]) -> [UUID: String] {
        var names: [UUID: String] = [:]
        var used = Set<String>()

        for pop in pops {
            let base = sanitizedPopletName(pop.name)
            var candidate = base
            var suffix = 2

            while used.contains(candidate.lowercased()) {
                candidate = "\(base) \(suffix)"
                suffix += 1
            }

            names[pop.id] = candidate
            used.insert(candidate.lowercased())
        }

        return names
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

    private func popletBundleURL(named popletName: String) -> URL {
        AppPaths.popletsDirectoryURL.appending(path: "\(popletName).app", directoryHint: .isDirectory)
    }

    private func movePopletIfNeeded(from oldName: String, to newName: String) throws -> Bool {
        let oldURL = popletBundleURL(named: oldName)
        let newURL = popletBundleURL(named: newName)

        return try withBundleLocks(for: [oldURL, newURL]) {
            guard oldURL != newURL, fileManager.fileExists(atPath: oldURL.path) else {
                return false
            }

            if !fileManager.fileExists(atPath: newURL.path) {
                try fileManager.moveItem(at: oldURL, to: newURL)
                return true
            }

            let parkedOldURL = temporarySiblingURL(for: oldURL, label: "renaming")
            let parkedNewURL = temporarySiblingURL(for: newURL, label: "occupied")
            var parkedExistingDestination = false

            try fileManager.moveItem(at: oldURL, to: parkedOldURL)
            do {
                if fileManager.fileExists(atPath: newURL.path) {
                    try fileManager.moveItem(at: newURL, to: parkedNewURL)
                    parkedExistingDestination = true
                }
                try fileManager.moveItem(at: parkedOldURL, to: newURL)
                if parkedExistingDestination, fileManager.fileExists(atPath: parkedNewURL.path) {
                    try fileManager.removeItem(at: parkedNewURL)
                }
                return true
            } catch {
                if fileManager.fileExists(atPath: parkedOldURL.path) {
                    try? fileManager.moveItem(at: parkedOldURL, to: oldURL)
                }
                if parkedExistingDestination, fileManager.fileExists(atPath: parkedNewURL.path) {
                    try? fileManager.moveItem(at: parkedNewURL, to: newURL)
                }
                throw error
            }
        }
    }

    private func writePopletBundle(
        for pop: PopRecord,
        popletName: String,
        paths: SharedContainerPaths
    ) throws -> PopletIconSource {
        let bundleURL = popletBundleURL(named: popletName)
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
                "CFBundleDisplayName": popletName,
                "CFBundleExecutable": popletExecutableName,
                "CFBundleIdentifier": "com.dockpops.companion.poplet.\(pop.id.uuidString.lowercased())",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundleName": popletName,
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

            try signGeneratedPopletBundle(at: stagingBundleURL)
            try installGeneratedPopletBundle(at: stagingBundleURL, destinationURL: bundleURL)
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

    private func loadRegistry(from url: URL) throws -> [String: String] {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    private func writeRegistry(_ registry: [String: String], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(registry)
        if
            fileManager.fileExists(atPath: url.path),
            let existingData = try? Data(contentsOf: url),
            existingData == data
        {
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private func removeOrphanedPoplets(previousRegistry: [String: String], desiredRegistry: [String: String]) throws -> Int {
        var removed = 0

        for name in previousRegistry.keys where desiredRegistry[name] == nil {
            let url = popletBundleURL(named: name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try withBundleLocks(for: [url]) {
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                    removed += 1
                }
            }
        }

        return removed
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

    private func installGeneratedPopletBundle(at stagingURL: URL, destinationURL: URL) throws {
        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
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
/// protected shared container for live per-Pop icon data. Poplets must read
/// only from the mirrored cache in `Application Support/DockPops Companion`.
///
/// If you are tempted to bypass this mirror and read `group.com.dockpops.shared`
/// directly from a poplet, stop. That is how we got back into repeated folder
/// prompts and generic blue fallback icons.
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
