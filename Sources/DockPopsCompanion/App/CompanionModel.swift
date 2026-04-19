import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CompanionModel {
    var pops: [PopRecord] = []
    var poplets: [PopletStatus] = []
    var stats = SyncStats.zero
    var isRefreshing = false
    var autoRefresh = false
    var hasSharedFolderAccess = false
    var metadataAvailable = false
    var dockPopsFound = false
    var errorDescription: String?
    var lastSync: Date?

    private let syncService = PopletSyncService()
    @ObservationIgnored private let iconCache = NSCache<NSString, NSImage>()
    private var refreshLoopTask: Task<Void, Never>?

    var statusTitle: String {
        if errorDescription != nil {
            return "Allow DockPops Access"
        }
        if !dockPopsFound {
            return "DockPops not found"
        }
        if !hasSharedFolderAccess {
            return "Allow DockPops Access"
        }
        if !metadataAvailable {
            return "Waiting for DockPops data"
        }
        if pops.isEmpty {
            return "No Pops found yet"
        }
        return "Poplets ready"
    }

    var statusMessage: String {
        if !dockPopsFound {
            return "Install or launch the App Store build of DockPops so the companion can locate it."
        }
        if let errorDescription {
            return "\(errorDescription) Press Refresh to let macOS ask again."
        }
        if !hasSharedFolderAccess {
            return "The companion reads DockPops data directly. macOS should ask once for permission the first time."
        }
        if !metadataAvailable {
            return "Open DockPops once so it writes shortcut metadata to the shared app-group folder."
        }
        if pops.isEmpty {
            return "Create at least one Pop in DockPops and the companion will generate Poplets in ~/Applications/DockPops."
        }
        return "This companion just creates poplets from DockPops. Manage icon styling in DockPops, then drag the poplets from Finder into the Dock."
    }

    var lastSyncText: String {
        guard let lastSync else { return "Never" }
        return lastSync.formatted(date: .abbreviated, time: .standard)
    }

    func start() {
        guard refreshLoopTask == nil else { return }
        refreshLoopTask = Task { [weak self] in
            guard let self else { return }
            await refreshNow()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                if autoRefresh && hasSharedFolderAccess {
                    await refreshNow()
                }
            }
        }
    }

    func stop() {
        refreshLoopTask?.cancel()
        refreshLoopTask = nil
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = syncService.sync()
        pops = snapshot.pops
        poplets = snapshot.poplets
        iconCache.removeAllObjects()
        stats = snapshot.stats
        hasSharedFolderAccess = snapshot.hasSharedContainerAccess
        metadataAvailable = snapshot.metadataAvailable
        dockPopsFound = snapshot.dockPopsFound
        errorDescription = snapshot.errorDescription
        lastSync = Date()
    }

    func openDockPops() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: AppPaths.dockPopsBundleIdentifier) else {
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func revealPopletsFolder() {
        NSWorkspace.shared.open(AppPaths.popletsDirectoryURL)
    }

    func icon(for poplet: PopletStatus) -> NSImage {
        let key = poplet.popletURL.path as NSString
        if let cached = iconCache.object(forKey: key) {
            return cached
        }

        let image = NSWorkspace.shared.icon(forFile: poplet.popletURL.path)
        image.size = NSSize(width: 256, height: 256)
        iconCache.setObject(image, forKey: key)
        return image
    }
}
