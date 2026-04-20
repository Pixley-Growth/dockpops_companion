import AppKit
import Foundation
import os

@MainActor
final class PopletSyncService {
    private static let logger = Logger(subsystem: "com.dockpops.companion", category: "PopletSync")
    private static let popletAppIconName = "AppIcon"

    private let fileManager = FileManager.default
    private let popStore = SharedPopStore()
    private var dockPopsIcon: NSImage?
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
            return try SharedContainerAccess.withAccess { containerURL in
                let paths = SharedContainerPaths(containerURL: containerURL)
                try ensureSharedContainerAccess(at: paths.containerURL)

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

        guard oldURL != newURL, fileManager.fileExists(atPath: oldURL.path) else {
            return false
        }

        if fileManager.fileExists(atPath: newURL.path) {
            try? fileManager.removeItem(at: newURL)
        }

        try fileManager.moveItem(at: oldURL, to: newURL)
        return true
    }

    private func writePopletBundle(
        for pop: PopRecord,
        popletName: String,
        paths: SharedContainerPaths
    ) throws -> PopletIconSource {
        let bundleURL = popletBundleURL(named: popletName)
        let contentsURL = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        let macOSURL = contentsURL.appending(path: "MacOS", directoryHint: .isDirectory)
        let resourcesURL = contentsURL.appending(path: "Resources", directoryHint: .isDirectory)
        let codeSignatureURL = contentsURL.appending(path: "_CodeSignature", directoryHint: .isDirectory)
        let codeResourcesURL = contentsURL.appending(path: "CodeResources")
        let appIconURL = resourcesURL.appending(path: "\(Self.popletAppIconName).icns")

        try ensureDirectory(bundleURL)
        if fileManager.fileExists(atPath: macOSURL.path) {
            try? fileManager.removeItem(at: macOSURL)
        }
        if fileManager.fileExists(atPath: resourcesURL.path) {
            try? fileManager.removeItem(at: resourcesURL)
        }
        if fileManager.fileExists(atPath: codeSignatureURL.path) {
            try? fileManager.removeItem(at: codeSignatureURL)
        }
        if fileManager.fileExists(atPath: codeResourcesURL.path) {
            try? fileManager.removeItem(at: codeResourcesURL)
        }
        try ensureDirectory(contentsURL)
        try ensureDirectory(macOSURL)
        try ensureDirectory(resourcesURL)
        try removeLegacyCustomIconArtifacts(from: bundleURL)

        let executableURL = macOSURL.appending(path: popletExecutableName)
        let infoPlistURL = contentsURL.appending(path: "Info.plist")
        let pkgInfoURL = contentsURL.appending(path: "PkgInfo")
        guard let bundledPopletURL = bundledPopletExecutableURL() else {
            throw NSError(
                domain: "DockPopsCompanion",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bundled DockPops poplet executable not found."]
            )
        }

        try fileManager.copyItem(at: bundledPopletURL, to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        stripCopiedLauncherSignatureIfPossible(at: executableURL)

        let resolvedIcon = resolvedPopletIcon(for: pop.id, paths: paths)
        let iconData = try generatedIconDataIfPossible(for: resolvedIcon.image)

        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": popletName,
            "CFBundleExecutable": popletExecutableName,
            "CFBundleIdentifier": "com.dockpops.companion.poplet.\(pop.id.uuidString.lowercased())",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": popletName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSPrincipalClass": "NSApplication",
            "DockPopsTargetPopID": pop.id.uuidString,
        ]
        if iconData != nil {
            plist["CFBundleIconFile"] = Self.popletAppIconName
        }
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: infoPlistURL, options: .atomic)
        try Data("APPL????".utf8).write(to: pkgInfoURL, options: .atomic)

        if let iconData {
            try iconData.write(to: appIconURL, options: .atomic)
        }

        try signGeneratedPopletBundle(at: bundleURL)
        refreshWorkspaceViews(for: bundleURL)
        return resolvedIcon.source
    }

    private func resolvedPopletIcon(for popID: UUID, paths: SharedContainerPaths) -> ResolvedPopletIcon {
        let popIconURL = paths.sharedPopIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
        if let image = NSImage(contentsOf: popIconURL) {
            let normalized = image.normalizedPopletAppIcon() ?? image
            return ResolvedPopletIcon(image: normalized, source: .popComposite)
        }

        if let dockPopsIcon = resolvedDockPopsIcon() {
            return ResolvedPopletIcon(image: dockPopsIcon, source: .dockPopsApp)
        }

        return ResolvedPopletIcon(image: nil, source: .generic)
    }

    private func inferredIconSource(for popID: UUID, paths: SharedContainerPaths) -> PopletIconSource {
        let popIconURL = paths.sharedPopIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
        if fileManager.fileExists(atPath: popIconURL.path) {
            return .popComposite
        }
        return dockPopsApplicationURL() == nil ? .generic : .dockPopsApp
    }

    private func resolvedDockPopsIcon() -> NSImage? {
        if let dockPopsIcon {
            return dockPopsIcon
        }
        guard let appURL = dockPopsApplicationURL() else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        dockPopsIcon = icon
        return icon
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
        let data = try JSONEncoder().encode(registry)
        try data.write(to: url, options: .atomic)
    }

    private func removeOrphanedPoplets(previousRegistry: [String: String], desiredRegistry: [String: String]) throws -> Int {
        var removed = 0

        for name in previousRegistry.keys where desiredRegistry[name] == nil {
            let url = popletBundleURL(named: name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
            removed += 1
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--remove-signature", executableURL.path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    Self.logger.error("signature strip failed for \(executableURL.lastPathComponent, privacy: .public): \(output, privacy: .public)")
                }
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw NSError(
                domain: "DockPopsCompanion",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "iconutil failed for generated poplet icon: \(output)"]
            )
        }

        return try Data(contentsOf: icnsURL)
    }

    private func removeLegacyCustomIconArtifacts(from bundleURL: URL) throws {
        let iconFileURL = bundleURL.appending(path: "Icon\r")
        if fileManager.fileExists(atPath: iconFileURL.path) {
            try? fileManager.removeItem(at: iconFileURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-d", "com.apple.FinderInfo", bundleURL.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Self.logger.error("Unable to clear Finder icon metadata for \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func signGeneratedPopletBundle(at bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", bundleURL.path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
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
        NSWorkspace.shared.noteFileSystemChanged(bundleURL.path)
        NSWorkspace.shared.noteFileSystemChanged(AppPaths.popletsDirectoryURL.path)
    }
}

private struct ResolvedPopletIcon {
    let image: NSImage?
    let source: PopletIconSource
}
