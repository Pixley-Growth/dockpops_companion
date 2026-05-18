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
    var hasSharedFolderAccess = false
    var hasStoredSharedAccessGrant = false
    var metadataAvailable = false
    var dockPopsFound = false
    var errorDescription: String?
    var lastSync: Date?
    var hasResolvedInitialLaunchState = false

    private let syncService = PopletSyncService()
    @ObservationIgnored
    private lazy var sharedContainerWatcher = SharedContainerWatcher { [weak self] in
        guard let self else { return }
        Task {
            await self.refreshNow()
        }
    }
    private var startupTask: Task<Void, Never>?

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
            return String(localized: "One quick setup step", comment: "Status title: shared-folder access warmup")
        }
        if errorDescription != nil {
            return String(localized: "Allow DockPops Access", comment: "Status title: needs shared-folder access")
        }
        if !dockPopsFound {
            return String(localized: "DockPops not found", comment: "Status title: DockPops app not installed")
        }
        if !hasSharedFolderAccess {
            return String(localized: "Allow DockPops Access", comment: "Status title: needs shared-folder access")
        }
        if !metadataAvailable {
            return String(localized: "Waiting for DockPops data", comment: "Status title: no metadata yet")
        }
        if pops.isEmpty {
            return String(localized: "No Pops found yet", comment: "Status title: no Pops created yet")
        }
        return String(localized: "Pop apps ready", comment: "Status title: Pop apps generated and ready")
    }

    var statusMessage: String {
        if !dockPopsFound {
            return String(localized: "Install or launch the App Store build of DockPops so the companion can locate it.", comment: "Status message: DockPops not found")
        }
        if needsSharedAccessWarmup {
            return String(localized: "The companion needs one-time access to DockPops' shared data folder. When you continue, that DockPops folder will open already selected, so you can just click Allow.", comment: "Status message: explains the one-time shared-folder access step")
        }
        if errorDescription != nil {
            return String(localized: "The DockPops shared folder will open already selected. Click Allow so this app can reconnect and keep itself in sync.", comment: "Status message: reconnect after a shared-folder access error")
        }
        if !hasSharedFolderAccess {
            return String(localized: "Continue and then click Allow so this app can keep itself in sync.", comment: "Status message: prompt to grant shared-folder access")
        }
        if !metadataAvailable {
            return String(localized: "Make or edit a Pop in DockPops. Pops you create or change there will appear here automatically.", comment: "Status message: waiting for DockPops data")
        }
        if pops.isEmpty {
            return String(localized: "Create at least one Pop in DockPops. Pops you make or modify there will appear here automatically.", comment: "Status message: no Pops created yet")
        }
        return String(localized: "Pops you make or modify in DockPops will appear here automatically. Then drag the ones you want into the Dock.", comment: "Status message: ready state")
    }

    var lastSyncText: String {
        guard let lastSync else {
            return String(localized: "Never", comment: "Last-sync time label when no sync has happened yet")
        }
        return lastSync.formatted(date: .abbreviated, time: .standard)
    }

    // MARK: - Lifecycle

    func start() {
        guard startupTask == nil else { return }
        sharedContainerWatcher.start()
        startupTask = Task { [weak self] in
            guard let self else { return }
            await loadInitialState()
        }
    }

    func stop() {
        startupTask?.cancel()
        startupTask = nil
        sharedContainerWatcher.stop()
    }

    // MARK: - Actions

    func continueToSharedAccessPrompt() async {
        // Re-entry guard. The first sync after a grant can take many seconds
        // (it generates a bundle for every Pop), and the permission screen
        // stays up the whole time. Without this guard a second click would
        // pop another folder panel — the cause of the "took 3 tries" report.
        guard !isRefreshing, !hasSharedFolderAccess else { return }

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

        // Run the file-I/O-heavy sync off the main actor so the window can
        // paint (and its launching spinner animate) instead of beach-balling.
        let service = syncService
        let snapshot = await Task.detached(priority: .userInitiated) {
            service.sync()
        }.value
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
        stats = snapshot.stats
        hasSharedFolderAccess = snapshot.hasSharedContainerAccess
        hasStoredSharedAccessGrant = snapshot.hasStoredSharedContainerBookmark
        metadataAvailable = snapshot.metadataAvailable
        dockPopsFound = snapshot.dockPopsFound
        errorDescription = snapshot.errorDescription
        lastSync = Date()

        if snapshot.hasStoredSharedContainerBookmark {
            sharedContainerWatcher.start()
        } else {
            sharedContainerWatcher.stop()
        }
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
}
