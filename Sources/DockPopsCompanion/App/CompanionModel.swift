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
    var hasStoredSharedAccessGrant = false
    var metadataAvailable = false
    var dockPopsFound = false
    var errorDescription: String?
    var lastSync: Date?

    private let syncService = PopletSyncService()
    @ObservationIgnored private let iconCache = NSCache<NSString, NSImage>()
    private var refreshLoopTask: Task<Void, Never>?

    var needsSharedAccessWarmup: Bool {
        dockPopsFound &&
        !hasSharedFolderAccess &&
        !hasStoredSharedAccessGrant &&
        errorDescription == nil
    }

    var statusTitle: String {
        if needsSharedAccessWarmup {
            return "One quick setup step"
        }
        if errorDescription != nil {
            return "Reconnect DockPops Access"
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
        if needsSharedAccessWarmup {
            return "The companion needs one-time access to DockPops' shared data folder. When you continue, you'll choose the group.com.dockpops.shared folder once and the companion will remember it for future launches."
        }
        if let errorDescription {
            return "\(errorDescription) Continue to choose the folder again."
        }
        if !hasSharedFolderAccess {
            return "Choose the DockPops shared folder once so this app can keep itself in sync."
        }
        if !metadataAvailable {
            return "Make or edit a Pop in DockPops. Pops you create or change there will appear here automatically."
        }
        if pops.isEmpty {
            return "Create at least one Pop in DockPops. Pops you make or modify there will appear here automatically."
        }
        return "Pops you make or modify in DockPops will appear here automatically. Then drag the ones you want into the Dock."
    }

    var lastSyncText: String {
        guard let lastSync else { return "Never" }
        return lastSync.formatted(date: .abbreviated, time: .standard)
    }

    func start() {
        guard refreshLoopTask == nil else { return }
        refreshLoopTask = Task { [weak self] in
            guard let self else { return }
            await loadInitialState()
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

    func continueToSharedAccessPrompt() async {
        do {
            try syncService.requestSharedContainerAccess()
            errorDescription = nil
        } catch let error as SharedContainerAccessError {
            if error == .userCancelled {
                return
            }
            errorDescription = error.localizedDescription
            return
        } catch {
            errorDescription = error.localizedDescription
            return
        }
        await refreshNow()
    }

    func refreshNow() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = syncService.sync()
        apply(snapshot)
    }

    private func loadInitialState() async {
        if syncService.hasStoredSharedContainerBookmark() {
            await refreshNow()
        } else {
            apply(syncService.startupSnapshot())
        }
    }

    private func apply(_ snapshot: SyncSnapshot) {
        pops = snapshot.pops
        poplets = snapshot.poplets
        iconCache.removeAllObjects()
        stats = snapshot.stats
        hasSharedFolderAccess = snapshot.hasSharedContainerAccess
        hasStoredSharedAccessGrant = snapshot.hasStoredSharedContainerBookmark
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
