import AppKit
import Foundation
import os

@MainActor
final class PopletSyncService {
    private static let logger = Logger(subsystem: "com.dockpops.companion", category: "PopletSync")

    private let fileManager = FileManager.default
    private let popStore = SharedPopStore()
    private var dockPopsIcon: NSImage?
    private let popletExecutableName = "DockPopsPoplet"

    func sync() -> SyncSnapshot {
        let dockPopsFound = dockPopsApplicationURL() != nil
        let paths = SharedContainerPaths(containerURL: AppPaths.expectedGroupContainerURL)

        guard dockPopsFound else {
            return SyncSnapshot(
                pops: [],
                poplets: [],
                stats: .zero,
                hasSharedContainerAccess: false,
                metadataAvailable: false,
                dockPopsFound: dockPopsFound,
                errorDescription: nil
            )
        }

        do {
            try ensureDirectory(AppPaths.popletsDirectoryURL)
            try ensureDirectory(AppPaths.companionSupportDirectoryURL)
            try ensureSharedContainerAccess(at: paths.containerURL)

            let metadataAvailable = fileManager.fileExists(atPath: paths.shortcutGroupsURL.path)

            guard metadataAvailable else {
                return SyncSnapshot(
                    pops: [],
                    poplets: loadExistingPoplets(paths: paths),
                    stats: .zero,
                    hasSharedContainerAccess: true,
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
                metadataAvailable: true,
                dockPopsFound: dockPopsFound,
                errorDescription: nil
            )
        } catch {
            if isMissingSharedContainer(error) {
                return SyncSnapshot(
                    pops: [],
                    poplets: loadExistingPoplets(paths: paths),
                    stats: .zero,
                    hasSharedContainerAccess: true,
                    metadataAvailable: false,
                    dockPopsFound: dockPopsFound,
                    errorDescription: nil
                )
            }

            Self.logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
            return SyncSnapshot(
                pops: [],
                poplets: [],
                stats: .zero,
                hasSharedContainerAccess: false,
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

            try writePopletBundle(for: pop, popletName: desiredName)
            let iconSource = applyBestEffortIcon(
                for: pop.id,
                popletURL: popletURL,
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

    private func isMissingSharedContainer(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError
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

    private func writePopletBundle(for pop: PopRecord, popletName: String) throws {
        let bundleURL = popletBundleURL(named: popletName)
        let contentsURL = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
        let macOSURL = contentsURL.appending(path: "MacOS", directoryHint: .isDirectory)
        let resourcesURL = contentsURL.appending(path: "Resources", directoryHint: .isDirectory)

        try ensureDirectory(bundleURL)
        if fileManager.fileExists(atPath: macOSURL.path) {
            try? fileManager.removeItem(at: macOSURL)
        }
        if fileManager.fileExists(atPath: resourcesURL.path) {
            try? fileManager.removeItem(at: resourcesURL)
        }
        try ensureDirectory(contentsURL)
        try ensureDirectory(macOSURL)
        try ensureDirectory(resourcesURL)

        let executableURL = macOSURL.appending(path: popletExecutableName)
        let infoPlistURL = contentsURL.appending(path: "Info.plist")
        guard let bundledPopletURL = bundledPopletExecutableURL() else {
            throw NSError(
                domain: "DockPopsCompanion",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Bundled DockPops poplet executable not found."]
            )
        }

        try fileManager.copyItem(at: bundledPopletURL, to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let plist: [String: Any] = [
            "CFBundleDisplayName": popletName,
            "CFBundleExecutable": popletExecutableName,
            "CFBundleIdentifier": "com.dockpops.companion.poplet.\(pop.id.uuidString.lowercased())",
            "CFBundleName": popletName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSPrincipalClass": "NSApplication",
            "DockPopsTargetPopID": pop.id.uuidString,
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: infoPlistURL, options: .atomic)
        try signBundleIfPossible(bundleURL)
    }

    private func applyBestEffortIcon(
        for popID: UUID,
        popletURL: URL,
        paths: SharedContainerPaths
    ) -> PopletIconSource {
        let popIconURL = paths.sharedPopIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
        if let image = NSImage(contentsOf: popIconURL) {
            let normalized = image.normalizedPopletAppIcon() ?? image
            NSWorkspace.shared.setIcon(normalized, forFile: popletURL.path, options: [])
            return .popComposite
        }

        if let dockPopsIcon = resolvedDockPopsIcon() {
            NSWorkspace.shared.setIcon(dockPopsIcon, forFile: popletURL.path, options: [])
            return .dockPopsApp
        }

        NSWorkspace.shared.setIcon(nil, forFile: popletURL.path, options: [])
        return .generic
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
        let primary = Bundle.main.resourceURL?
            .appending(path: "PopletSupport", directoryHint: .isDirectory)
            .appending(path: popletExecutableName)
        if let primary, fileManager.fileExists(atPath: primary.path) {
            return primary
        }
        return nil
    }

    private func signBundleIfPossible(_ bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", bundleURL.path]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8), !output.isEmpty {
                    Self.logger.error("codesign failed for \(bundleURL.lastPathComponent, privacy: .public): \(output, privacy: .public)")
                }
            }
        } catch {
            Self.logger.error("Unable to run codesign for \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
