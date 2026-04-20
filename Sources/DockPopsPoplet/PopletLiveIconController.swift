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

    private let popID: UUID
    private let watchedDirectoryURL: URL
    private let popIconURL: URL

    private var directorySource: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?

    init(popID: UUID) {
        self.popID = popID
        self.watchedDirectoryURL = PopletSharedPaths.popIconsDirectoryURL
        self.popIconURL = PopletSharedPaths.popIconURL(for: popID)
    }

    func start() {
        applyLatestIcon()
        installDirectoryWatcher()
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        directorySource?.cancel()
        directorySource = nil
    }

    private func applyLatestIcon() {
        guard let rawImage = PopletIconRendering.loadImage(at: popIconURL) else {
            // No shared PNG yet — leave the baked bundle icon visible.
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
        let fd = open(watchedDirectoryURL.path, O_EVTONLY)
        guard fd >= 0 else {
            Self.logger.error(
                "open failed for \(self.watchedDirectoryURL.path, privacy: .public)"
            )
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedRefresh()
            }
        }
        source.setCancelHandler { [fd] in
            close(fd)
        }
        source.resume()
        directorySource = source
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.applyLatestIcon()
        }
    }
}
