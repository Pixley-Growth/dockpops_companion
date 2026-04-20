import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class CompanionModel {
    enum ScreenState {
        case launching
        case sharedAccess
        case waitingForMetadata
        case empty
        case ready
    }

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
    var hasResolvedInitialLaunchState = false

    private let syncService = PopletSyncService()
    @ObservationIgnored private let iconCache = NSCache<NSString, NSImage>()
    private var refreshLoopTask: Task<Void, Never>?

    // MARK: - Presentation

    var needsSharedAccessWarmup: Bool {
        dockPopsFound &&
        !hasSharedFolderAccess &&
        !hasStoredSharedAccessGrant &&
        errorDescription == nil
    }

    /// Presentation order matters here.
    /// Shared-folder recovery must win before metadata/empty states so first launch,
    /// revoked permission, and missing DockPops installs all funnel through the same
    /// reconnect surface instead of partially rendering the browser.
    var screenState: ScreenState {
        if !hasResolvedInitialLaunchState {
            return .launching
        }
        if !hasSharedFolderAccess {
            return .sharedAccess
        }
        if !metadataAvailable {
            return .waitingForMetadata
        }
        if poplets.isEmpty {
            return .empty
        }
        return .ready
    }

    var statusTitle: String {
        if needsSharedAccessWarmup {
            return "One quick setup step"
        }
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
        if needsSharedAccessWarmup {
            return "The companion needs one-time access to DockPops' shared data folder. When you continue, that DockPops folder will open already selected, so you can just click Allow."
        }
        if errorDescription != nil {
            return "The DockPops shared folder will open already selected. Click Allow so this app can reconnect and keep itself in sync."
        }
        if !hasSharedFolderAccess {
            return "Continue and then click Allow so this app can keep itself in sync."
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

    // MARK: - Lifecycle

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

    // MARK: - Actions

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

    // MARK: - Private

    private func loadInitialState() async {
        // Never surprise-prompt on launch. If we already have a valid bookmark,
        // refresh immediately; otherwise render the warmup screen first.
        if syncService.hasStoredSharedContainerBookmark() {
            await refreshNow()
        } else {
            apply(syncService.startupSnapshot())
        }
        hasResolvedInitialLaunchState = true
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

    // MARK: - UI Helpers

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
        let key = iconCacheKey(for: poplet)
        if let cached = iconCache.object(forKey: key) {
            return cached
        }

        let image = loadIconImage(for: poplet)
        image.size = NSSize(width: 256, height: 256)
        iconCache.setObject(image, forKey: key)
        return image
    }

    private func iconCacheKey(for poplet: PopletStatus) -> NSString {
        let iconURL = poplet.popletURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "AppIcon.icns")

        if let values = try? iconURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) {
            let timestamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            let size = values.fileSize ?? 0
            return "\(poplet.popletURL.path)#\(timestamp)#\(size)" as NSString
        }

        return poplet.popletURL.path as NSString
    }

    private func loadIconImage(for poplet: PopletStatus) -> NSImage {
        let iconURL = poplet.popletURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "AppIcon.icns")

        if let image = NSImage(contentsOf: iconURL) {
            return image
        }

        return NSWorkspace.shared.icon(forFile: poplet.popletURL.path)
    }
}
