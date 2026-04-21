import AppKit
import Darwin
import Foundation
import os

@MainActor
final class PopletSyncService {
    private static let logger = Logger(subsystem: "com.dockpops.companion", category: "PopletSync")
    private static let popletAppIconName = "AppIcon"
    /// Bump when the poplet icon rendering recipe changes even if the source
    /// PopIcons PNG does not. This forces unopened poplets onto a fresh bundle
    /// version so Dock/Finder stop serving stale cached icons.
    private static let popletIconRecipeVersion = 3
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
        return try withBundleLocks(for: [bundleURL]) {
            let executableURL = macOSURL.appending(path: popletExecutableName)
            let infoPlistURL = contentsURL.appending(path: "Info.plist")
            let pkgInfoURL = contentsURL.appending(path: "PkgInfo")
            let iconData = try generatedIconDataIfPossible(for: resolvedIcon.image)

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
                "LSMinimumSystemVersion": "14.0",
                "NSPrincipalClass": "NSApplication",
                Self.popletIconRecipeVersionInfoKey: Self.popletIconRecipeVersion,
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

            try signGeneratedPopletBundle(at: stagingBundleURL)
            try installGeneratedPopletBundle(at: stagingBundleURL, destinationURL: bundleURL)
            refreshWorkspaceViews(for: bundleURL)
            return resolvedIcon.source
        }
    }

    private func resolvedPopletIcon(for popID: UUID, paths: SharedContainerPaths) -> ResolvedPopletIcon {
        let baseBuildVersion = currentCompanionBuildVersion()
        let popIconURL = paths.sharedPopIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
        if let image = NSImage(contentsOf: popIconURL) {
            let normalized = image.normalizedPopletAppIcon() ?? image
            return ResolvedPopletIcon(
                image: normalized,
                source: .popComposite,
                bundleVersion: bundleVersionForPopComposite(at: popIconURL, baseBuildVersion: baseBuildVersion)
            )
        }

        if let dockPopsIcon = resolvedDockPopsIcon() {
            return ResolvedPopletIcon(
                image: dockPopsIcon,
                source: .dockPopsApp,
                bundleVersion: baseBuildVersion
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

    private func resolvedDockPopsIcon() -> NSImage? {
        guard let appURL = dockPopsApplicationURL() else { return nil }
        return NSWorkspace.shared.icon(forFile: appURL.path)
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

    private func signGeneratedPopletBundle(at bundleURL: URL) throws {
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
