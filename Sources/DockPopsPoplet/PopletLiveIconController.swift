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
    /// B — proactive-heal debounce. The running Poplet tile follows the bundle's
    /// HEALED icon (Finder-custom-icon / Tahoe-plate escape hatch), NOT
    /// `applicationIconImage`. So when MAIN writes a fresh PNG we must heal the
    /// bundle BEFORE the click. Fire the same on-click heal here, debounced by
    /// `healSettleDelay` so a color-drag's PNG stream heals ONCE after it settles —
    /// avoiding the SACRED-#28 per-event "generic folder" flash.
    private var healDebounceTask: Task<Void, Never>?
    private let healSettleDelay: Duration = .milliseconds(600)

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
    /// Reads the 256² live composite PNG from the **non-gated**
    /// `~/Applications/DockPops/Icons/<uuid>.live.png` (written by the
    /// generator as a verbatim byte-copy) and applies it to
    /// `NSApp.applicationIconImage`. Call from
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
    /// TCC (2026-05-29): this MUST read the non-gated `Icons/` folder, never
    /// the `group.com.dockpops.shared` App Group container. An ad-hoc Poplet
    /// is not a group member (membership is per-binary signature), so a
    /// container read — even by absolute path — trips the macOS 26 "data from
    /// other apps" prompt on every click. The earlier note here claiming an
    /// absolute-path container read is prompt-free was WRONG; the win is the
    /// folder being non-gated, not the path being hardcoded.
    ///
    /// DO NOT change the file extension. The generator writes `.live.png`
    /// (256²) specifically for Poplet consumption; the larger master `.png`
    /// would burn resident memory for no visual gain because
    /// `NSApp.applicationIconImage` retains the source-resolution bitmap for
    /// the process lifetime.
    ///
    /// DO NOT remove the call sites in DockPopsPopletMain
    /// `applicationDidFinishLaunching` and `applicationShouldHandleReopen`
    /// (via `PopletLiveIconController.start()` and the reopen hook).
    /// Removing either re-introduces the "icons don't update unless
    /// Companion is running" regression.
    /// ════════════════════════════════════════════════════════════════
    func refreshFromSharedContainer() {
        // TCC fix (2026-05-29): read the 256² live PNG from the NON-GATED
        // `~/Applications/DockPops/Icons/<uuid>.live.png`, never the App Group
        // container. An ad-hoc Poplet isn't a group member, so a container read
        // trips the "data from other apps" prompt on every click. The generator
        // writes a verbatim byte-copy here. See PopletSharedPaths SACRED note.
        let liveURL = PopletSharedPaths.iconLiveURL(for: popID)
        let data = try? Data(contentsOf: liveURL)
        Self.logger.notice("2CLICK refresh policy=\(NSApp.activationPolicy().rawValue, privacy: .public) bytes=\(data?.count ?? -1, privacy: .public)")
        guard let data else { return }
        applyIconFromIPC(data)
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        settleRetryTask?.cancel()
        settleRetryTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        healDebounceTask?.cancel()
        healDebounceTask = nil
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

    /// Sets the Dock-tile icon on the NEXT runloop turn (never synchronously) and
    /// forces an immediate recomposite. A Dock click drives this resident
    /// `.accessory` Poplet through a transient `.regular` activation edge; a
    /// SYNCHRONOUS `applicationIconImage` set inside `applicationShouldHandleReopen`
    /// runs DURING that edge and gets clobbered when AppKit re-reads the bundle icon
    /// — the persistent "two clicks to update" bug. Deferring past the edge +
    /// `dockTile.display()` makes the fresh icon stick on the FIRST click. The
    /// live-IPC and directory-watcher paths funnel through here too, so they inherit
    /// the fix. (Mirror of the same fix in the main DockPops repo's DockPopsPoplet.)
    private func setDockIcon(_ image: NSImage?) {
        Task { @MainActor in
            NSApp.applicationIconImage = image
            NSApp.dockTile.display()
            Self.logger.notice("2CLICK setDockIcon applied (deferred)")
        }
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
                setDockIcon(decoded)
                lastAppliedIconSignature = nil
            }
            return
        }
        let image = NSImage(
            cgImage: normalized,
            size: NSSize(width: CGFloat(normalized.width), height: CGFloat(normalized.height))
        )
        setDockIcon(image)
        lastAppliedIconSignature = nil
    }

    private func applyLatestIcon() -> RefreshResult {
        guard let popIconURL else {
            setDockIcon(fallbackApplicationIconImage())
            return .missing
        }
        guard let signature = currentIconSignature() else {
            // The mirrored PNG may be missing temporarily or gone for good.
            // Fall back to the current DockPops app icon if available so the
            // live poplet never snaps back to a stale baked/default icon.
            lastAppliedIconSignature = nil
            setDockIcon(fallbackApplicationIconImage())
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
        setDockIcon(image)
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

        // No `.attrib`: matches the same exclusion in SharedContainerWatcher.
        // `.attrib` fires on xattr / permission / FinderInfo changes that
        // macOS background work (Spotlight, LaunchServices, container
        // journaling) ticks at multiple Hz while idle. Real live-icon PNG
        // updates still fire as `.write` / `.extend` / `.rename` / `.delete`.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
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
        scheduleProactiveHeal()
    }

    /// B: heal this Poplet's bundle icon PROACTIVELY when MAIN writes a fresh PNG,
    /// so the tile is correct on the FIRST click without the Companion running.
    /// Runs the SAME full heal the reopen path runs (icns + Finder-icon + re-sign),
    /// just fired on the settled directory-watcher edit instead of one click late.
    /// Debounced + off the main actor; `healIfStale`'s `bundleNeedsHeal` no-ops when
    /// nothing changed, so the 2–3 redundant FS events of an atomic write cost nothing.
    private func scheduleProactiveHeal() {
        healDebounceTask?.cancel()
        let popID = self.popID
        let bundleURL = Bundle.main.bundleURL
        let delay = healSettleDelay
        healDebounceTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await PopletBundleIconHealer(popID: popID, bundleURL: bundleURL).healIfStale()
            await self?.reapplyAfterHeal()
        }
    }

    /// Reopen-click heal: heal off-main, then re-apply the icon so the running tile
    /// flips on THIS click instead of the next one. Called from
    /// `applicationShouldHandleReopen` (replaces the inline detached healer).
    func healOnClick() {
        let popID = self.popID
        let bundleURL = Bundle.main.bundleURL
        Task.detached(priority: .utility) { [weak self] in
            await PopletBundleIconHealer(popID: popID, bundleURL: bundleURL).healIfStale()
            await self?.reapplyAfterHeal()
        }
    }

    /// Re-apply the icon on the main actor AFTER a heal completes. The heal strips
    /// the macOS-26 Tahoe plate (via the Finder custom icon); the log proved the
    /// tile only picks up the un-plated artwork on a FRESH `applicationIconImage`
    /// set — which otherwise only happens on the next click. Doing it here removes
    /// that extra click. Clears the signature dedup: the PNG bytes didn't change,
    /// only the plate state flipped.
    @MainActor
    private func reapplyAfterHeal() {
        lastAppliedIconSignature = nil
        _ = applyLatestIcon()
        Self.logger.notice("2CLICK reapplyAfterHeal (post-heal re-apply)")
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
