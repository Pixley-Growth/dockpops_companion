import AppKit
import Foundation
import os

/// SACRED CODE:
/// The running poplet must consume live icons only from the companion-owned
/// mirrored cache. It must not read DockPops' protected shared container or
/// private prefs directly.
///
/// Method B keeps the running poplet's Dock tile mirroring that companion live
/// icon cache. It is purely in-memory via `NSApp.applicationIconImage`, so it
/// can never invalidate the bundle signature.
///
/// Watches the mirrored `PopletLiveIcons/` directory rather than the specific
/// PNG file so atomic-rename writes (new inode) still fire events.
@MainActor
final class PopletLiveIconController {
    private struct IconFileSignature: Equatable {
        let modificationDate: Date
        let fileSize: Int
    }

    private enum RefreshResult {
        case applied
        case unchanged
        case pending
        case missing
    }

    private static let logger = Logger(
        subsystem: "com.dockpops.companion.poplet",
        category: "LiveIcon"
    )

    /// DistributedNotification name DockPops Main posts to push live icon
    /// updates straight to running Poplets. Pairs with `openRequest` —
    /// together they form the "no Companion required" IPC surface.
    /// See `docs/specs/dockpops-main-direct-ipc.md`.
    static let iconUpdateNotificationName = "com.dockpops.poplet.iconUpdated"

    private let fileManager = FileManager.default
    private let popID: UUID
    private let bundleURL: URL
    private let watchedDirectoryURL: URL?
    private let popIconURL: URL?

    private var directorySource: DispatchSourceFileSystemObject?
    private var iconUpdateObserver: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var settleRetryTask: Task<Void, Never>?
    private var watcherRetryTask: Task<Void, Never>?
    private var lastAppliedIconSignature: IconFileSignature?
    /// Timestamp of the most recent `applyLatestIcon` fire. Drives the
    /// leading-edge throttle in `scheduleDebouncedRefresh` so continuous FS
    /// events (e.g. a held color drag in the main app firing a PNG write
    /// every ~100ms) don't starve the Poplet of updates.
    private var lastApplyAt: ContinuousClock.Instant?
    /// Minimum interval between `applyLatestIcon` fires. Small enough to
    /// keep the Poplet tile in near-lockstep with the main app's Dock tile,
    /// large enough to coalesce the 2-3 redundant FS events an atomic PNG
    /// write produces (rename + attrib).
    private let applyCooldown: Duration = .milliseconds(80)
    /// Directory notifications can land just before the target PNG's metadata
    /// or contents visibly flip. A short confirmation retry keeps the live
    /// tile from getting stuck one move behind on discrete organizer edits.
    private let settleDelay: Duration = .milliseconds(50)

    init(
        popID: UUID,
        liveIconsDirectoryURL: URL? = PopletSharedPaths.mirroredPopIconsDirectoryURL,
        bundleURL: URL = Bundle.main.bundleURL
    ) {
        self.popID = popID
        self.bundleURL = bundleURL
        self.watchedDirectoryURL = liveIconsDirectoryURL
        self.popIconURL = liveIconsDirectoryURL.map { liveIconsDirectoryURL in
            liveIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
        }

        if let liveIconsDirectoryURL {
            PopletSharedPaths.assertUsesMirroredLiveIconsDirectory(liveIconsDirectoryURL)
        }
        if let popIconURL {
            PopletSharedPaths.assertUsesMirroredLiveIconFile(popIconURL)
        }
    }

    func start() {
        stop()
        // Poll-on-launch first (reads the canonical disk PNG straight from
        // the shared container) so even cold-launched Poplets paint with
        // the current icon when Companion has never run / mirror is empty.
        // See `refreshFromSharedContainer()` for the read path + SACRED
        // rationale.
        refreshFromSharedContainer()
        // Companion's mirror watcher still runs as defense-in-depth — when
        // Companion IS running, the mirror PNG matches the shared container
        // PNG byte-for-byte and the file watcher gives sub-second live
        // updates during running edits. Both paths set
        // `NSApp.applicationIconImage` to the same content so there's no
        // flicker.
        _ = applyLatestIcon()
        installDirectoryWatcher()
        installIconUpdateObserver()
    }

    /// ════════════════════════════════════════════════════════════════
    /// SACRED ZONE #27 — Poll-on-click composite refresh
    /// ════════════════════════════════════════════════════════════════
    ///
    /// Reads the 256×256 composite PNG straight from the shared
    /// container's `PopIcons/<uuid>.live.png` sidecar (Main writes it
    /// atomically there alongside the 1024² `<uuid>.png` for Companion's
    /// icns) and applies it to `NSApp.applicationIconImage`. Call from
    /// `applicationDidFinishLaunching` (initial paint) and from
    /// `applicationShouldHandleReopen` (catches Pop edits made while the
    /// Poplet wasn't running OR while Companion wasn't running).
    ///
    /// Why this method exists: the DNC `iconUpdated` IPC alone is not
    /// sufficient — `DistributedNotificationCenter` does not queue, so
    /// events posted while the Poplet is quit are silently dropped.
    /// Disk poll-on-click is the only reliable "Poplet picks up Pop edits
    /// made while everything was off" pathway.
    ///
    /// DO NOT change the file extension. Main writes `.live.png` (256²)
    /// specifically for Poplet consumption; the 1024² `.png` would burn
    /// ~75 MB resident across 20 Poplets for no visual gain because
    /// `NSApp.applicationIconImage` retains the source-resolution bitmap
    /// for the process lifetime. See
    /// /Users/etoduarte/0. Coding/Swift/3. DockPops/docs/handoffs/
    /// companion-poplet-poll-on-click.md § "Memory profile" for the
    /// arithmetic.
    ///
    /// DO NOT remove the call sites in DockPopsPopletMain
    /// `applicationDidFinishLaunching` and `applicationShouldHandleReopen`
    /// (via `PopletLiveIconController.start()` and the reopen hook).
    /// Removing either re-introduces the "icons don't update unless
    /// Companion is running" regression.
    /// ════════════════════════════════════════════════════════════════
    ///
    /// Per cross-repo handoff `docs/handoffs/companion-poplet-poll-on-click.md`
    /// in DockPops Main (2026-05-20, revision 2):
    ///   • Main writes THREE files atomically per scheduleExport cycle:
    ///     `<uuid>.png` (1024²) for Companion's icns generation,
    ///     `<uuid>.live.png` (256²) for Poplets, and the canonical
    ///     `<uuid>.fingerprint`.
    ///   • Companion's Poplet reads `.live.png` directly via absolute
    ///     path. NO App Group entitlement, NO security-scoped bookmark,
    ///     NO Companion dependency. Just POSIX file read.
    ///   • Why .live.png and not .png: `NSApp.applicationIconImage`
    ///     retains the source-resolution bitmap for the Poplet's
    ///     lifetime. 20 Poplets × 4 MB (1024² RGBA) = ~80 MB resident.
    ///     256² source = ~5 MB. The Dock tile is at most ~256 px on
    ///     Retina at the largest Dock setting, so the larger file would
    ///     be wasted bytes for zero visual gain.
    ///   • Same bytes as the DNC broadcast: Main computes the 256² PNG
    ///     once per cycle and uses identical bytes for both `.live.png`
    ///     and the `iconUpdated` userInfo. No divergence possible.
    ///
    /// SACRED relaxation (2026-05-20):
    /// `DockPopsPopletMain.applicationDidFinishLaunching`'s SACRED block
    /// previously stated "Poplets must never reopen shared-container
    /// access on launch." That SACRED was about App Group ENTITLEMENT
    /// access (which triggers TCC prompts on every click for ad-hoc
    /// signed bundles per macOS 26). This call does NOT use the
    /// entitlement — it uses a hardcoded absolute path. POSIX
    /// permissions on the App Group container directory are
    /// `drwx------` user-owned, so any process running as the user
    /// (which the Poplet does — no sandbox, no entitlements) can read
    /// the contents when the path is known. Verified empirically.
    func refreshFromSharedContainer() {
        let liveURL = Self.sharedPopIconDirectory
            .appending(path: "\(popID.uuidString).live.png")
        guard let data = try? Data(contentsOf: liveURL) else { return }
        applyIconFromIPC(data)
    }

    /// Hardcoded path to Main's `PopIcons/` directory in the App Group
    /// container. Poplets cannot resolve `group.com.dockpops.shared` via
    /// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`
    /// because they're ad-hoc signed and don't carry the App Group
    /// entitlement — so this constant hardcodes the absolute path under
    /// `~/Library/Group Containers/`. macOS allows cross-process reads
    /// of app group containers via direct path when the caller has
    /// POSIX read permission (which is "process runs as the file's
    /// owner" — true here since both Main and the Poplet run as the
    /// user).
    private static let sharedPopIconDirectory: URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers")
            .appending(path: "group.com.dockpops.shared")
            .appending(path: "PopIcons")
    }()

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        settleRetryTask?.cancel()
        settleRetryTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        invalidateDirectoryWatcher()
        removeIconUpdateObserver()
    }

    /// Pull live icons directly from DockPops Main via DistributedNotification.
    /// Works whether or not the Companion is running — the Companion's mirror
    /// directory above remains as a fallback for the initial paint while the
    /// Poplet starts up, but real-time updates now arrive over IPC.
    private func installIconUpdateObserver() {
        iconUpdateObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Self.iconUpdateNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Swift 6: extract Sendable values before crossing the actor.
            let popIDString = notification.userInfo?["pop"] as? String
            let iconData = notification.userInfo?["iconData"] as? Data
            Task { @MainActor in
                self?.handleIconUpdate(popIDString: popIDString, iconData: iconData)
            }
        }
    }

    private func removeIconUpdateObserver() {
        if let iconUpdateObserver {
            DistributedNotificationCenter.default().removeObserver(iconUpdateObserver)
        }
        iconUpdateObserver = nil
    }

    private func handleIconUpdate(popIDString: String?, iconData: Data?) {
        // DistributedNotifications broadcast to every running Poplet; each
        // process filters by its own popID and acts only on its own updates.
        guard let popIDString, popIDString == popID.uuidString else { return }
        guard let iconData, !iconData.isEmpty else {
            Self.logger.error("iconUpdated received with missing payload for \(self.popID.uuidString, privacy: .public)")
            return
        }
        applyIconFromIPC(iconData)
    }

    /// Apply an icon delivered over IPC. Bypasses the file-watcher signature
    /// dedup (which compares mtime + filesize of the mirrored PNG on disk).
    /// Clearing `lastAppliedIconSignature` lets a later file-watcher fire
    /// re-validate against disk so the two paths stay convergent.
    private func applyIconFromIPC(_ data: Data) {
        guard
            let rawImage = PopletIconRendering.loadImage(from: data),
            let normalized = PopletIconRendering.normalizedCanvas(from: rawImage)
        else {
            // If the inset/mask normalizer can't run, fall back to the raw
            // decode so the Poplet at least picks up the new artwork.
            if let decoded = NSImage(data: data) {
                NSApp.applicationIconImage = decoded
                lastAppliedIconSignature = nil
            }
            return
        }
        let image = NSImage(
            cgImage: normalized,
            size: NSSize(width: CGFloat(normalized.width), height: CGFloat(normalized.height))
        )
        NSApp.applicationIconImage = image
        lastAppliedIconSignature = nil
    }

    private func applyLatestIcon() -> RefreshResult {
        guard let popIconURL else {
            NSApp.applicationIconImage = fallbackApplicationIconImage()
            return .missing
        }
        guard let signature = currentIconSignature() else {
            // The mirrored PNG may be missing temporarily or gone for good.
            // Fall back to the current DockPops app icon if available so the
            // live poplet never snaps back to a stale baked/default icon.
            lastAppliedIconSignature = nil
            NSApp.applicationIconImage = fallbackApplicationIconImage()
            return .missing
        }
        guard signature != lastAppliedIconSignature else { return .unchanged }
        guard
            let data = try? Data(contentsOf: popIconURL),
            let decodedImage = NSImage(data: data)
        else {
            return .pending
        }
        let image: NSImage
        if
            let rawImage = PopletIconRendering.loadImage(from: data),
            let normalized = PopletIconRendering.normalizedCanvas(from: rawImage)
        {
            image = NSImage(
                cgImage: normalized,
                size: NSSize(width: CGFloat(normalized.width), height: CGFloat(normalized.height))
            )
        } else {
            image = decodedImage
        }
        // The mirrored PNG is already the final composed app icon. Show it on
        // a presentation canvas so the running tile matches the intended
        // poplet app-icon size instead of filling the Dock too aggressively.
        NSApp.applicationIconImage = image
        lastAppliedIconSignature = signature
        return .applied
    }

    private func installDirectoryWatcher() {
        guard directorySource == nil else { return }
        guard let watchedDirectoryURL else { return }

        let fd = open(watchedDirectoryURL.path, O_EVTONLY)
        guard fd >= 0 else {
            if fileManager.fileExists(atPath: watchedDirectoryURL.path) {
                Self.logger.error(
                    "open failed for \(watchedDirectoryURL.path, privacy: .public)"
                )
            } else {
                Self.logger.notice(
                    "waiting for mirrored live-icon directory at \(watchedDirectoryURL.path, privacy: .public)"
                )
            }
            scheduleWatcherRetry()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { [weak self] in
                self?.handleWatchedDirectoryEvent()
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        directorySource = source
        refreshAfterWatcherAttach()
    }

    /// Leading + trailing-edge throttle. First FS event after `applyCooldown`
    /// of silence fires immediately (so the Poplet tracks main-app updates in
    /// near-real-time during continuous drags); subsequent events during the
    /// cooldown sleep just long enough to hit the cooldown boundary and then
    /// apply. Replaces a pure trailing-edge 250ms debounce that kept resetting
    /// during continuous main-app writes and never applied until ~250ms after
    /// the drag ended.
    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        settleRetryTask?.cancel()
        settleRetryTask = nil

        let now = ContinuousClock.now
        let timeSinceLast: Duration
        if let last = lastApplyAt {
            timeSinceLast = now - last
        } else {
            timeSinceLast = .seconds(999)
        }
        let delay: Duration = timeSinceLast >= applyCooldown
            ? .zero
            : applyCooldown - timeSinceLast

        debounceTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            guard let self else { return }
            self.lastApplyAt = ContinuousClock.now
            switch self.applyLatestIcon() {
            case .applied, .missing:
                break
            case .unchanged, .pending:
                self.scheduleSettleRetry()
            }
        }
    }

    private func scheduleSettleRetry() {
        settleRetryTask?.cancel()

        settleRetryTask = Task { [weak self] in
            try? await Task.sleep(for: self?.settleDelay ?? .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.settleRetryTask = nil

            switch self.applyLatestIcon() {
            case .applied, .unchanged, .missing:
                break
            case .pending:
                self.scheduleSettleRetry()
            }
        }
    }

    private func currentIconSignature() -> IconFileSignature? {
        guard let popIconURL else { return nil }
        guard fileManager.fileExists(atPath: popIconURL.path) else { return nil }
        let values = try? popIconURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return IconFileSignature(
            modificationDate: values?.contentModificationDate ?? .distantPast,
            fileSize: values?.fileSize ?? -1
        )
    }

    private func handleWatchedDirectoryEvent() {
        guard let watchedDirectoryURL else { return }
        guard fileManager.fileExists(atPath: watchedDirectoryURL.path) else {
            invalidateDirectoryWatcher()
            scheduleWatcherRetry()
            _ = applyLatestIcon()
            return
        }
        scheduleDebouncedRefresh()
    }

    private func refreshAfterWatcherAttach() {
        switch applyLatestIcon() {
        case .pending, .unchanged:
            scheduleSettleRetry()
        case .applied, .missing:
            break
        }
    }

    private func fallbackApplicationIconImage() -> NSImage {
        if
            let dockPopsURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: PopletSharedPaths.dockPopsBundleIdentifier
            )
        {
            return NSWorkspace.shared.icon(forFile: dockPopsURL.path)
        }

        return NSWorkspace.shared.icon(forFile: bundleURL.path)
    }

    private func invalidateDirectoryWatcher() {
        directorySource?.cancel()
        directorySource = nil
    }

    private func scheduleWatcherRetry() {
        guard watcherRetryTask == nil else { return }

        watcherRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.watcherRetryTask = nil
            self.installDirectoryWatcher()
        }
    }
}
