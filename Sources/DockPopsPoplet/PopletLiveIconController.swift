import AppKit
import Foundation
import os

/// Method B — keeps the running poplet's Dock tile mirroring the shared pop
/// composite PNG. Purely in-memory via `NSApp.applicationIconImage`, so it can
/// never invalidate the bundle signature.
///
/// Watches the `PopIcons/` directory rather than the specific PNG file so
/// atomic-rename writes (new inode) still fire events.
@MainActor
final class PopletLiveIconController {
    private static let logger = Logger(
        subsystem: "com.dockpops.companion.poplet",
        category: "LiveIcon"
    )

    private let fileManager = FileManager.default
    private let bundleURL: URL
    private let watchedDirectoryURL: URL
    private let popIconURL: URL

    private var directorySource: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private var watcherRetryTask: Task<Void, Never>?
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

    init(popID: UUID, bundleURL: URL = Bundle.main.bundleURL) {
        self.bundleURL = bundleURL
        self.watchedDirectoryURL = PopletSharedPaths.popIconsDirectoryURL
        self.popIconURL = PopletSharedPaths.popIconURL(for: popID)
    }

    func start() {
        stop()
        applyLatestIcon()
        installDirectoryWatcher()
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        watcherRetryTask?.cancel()
        watcherRetryTask = nil
        directorySource?.cancel()
        directorySource = nil
    }

    private func applyLatestIcon() {
        guard let rawImage = PopletIconRendering.loadImage(at: popIconURL) else {
            // The shared PNG may be missing temporarily or gone for good. Fall
            // back to the bundle icon so the running tile does not stay stale.
            NSApp.applicationIconImage = NSWorkspace.shared.icon(forFile: bundleURL.path)
            return
        }
        let presented = PopletIconRendering.normalizedCanvas(from: rawImage) ?? rawImage
        let nsImage = NSImage(
            cgImage: presented,
            size: NSSize(
                width: CGFloat(presented.width),
                height: CGFloat(presented.height)
            )
        )
        NSApp.applicationIconImage = nsImage
    }

    private func installDirectoryWatcher() {
        guard directorySource == nil else { return }

        let fd = open(watchedDirectoryURL.path, O_EVTONLY)
        guard fd >= 0 else {
            if fileManager.fileExists(atPath: watchedDirectoryURL.path) {
                Self.logger.error(
                    "open failed for \(self.watchedDirectoryURL.path, privacy: .public)"
                )
            } else {
                Self.logger.notice(
                    "waiting for PopIcons directory at \(self.watchedDirectoryURL.path, privacy: .public)"
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
                self?.scheduleDebouncedRefresh()
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        directorySource = source
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
            self.applyLatestIcon()
        }
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
