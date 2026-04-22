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

    private let fileManager = FileManager.default
    private let bundleURL: URL
    private let watchedDirectoryURL: URL?
    private let popIconURL: URL?

    private var directorySource: DispatchSourceFileSystemObject?
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
        _ = applyLatestIcon()
        installDirectoryWatcher()
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        settleRetryTask?.cancel()
        settleRetryTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        invalidateDirectoryWatcher()
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
