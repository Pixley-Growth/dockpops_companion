import Foundation
import os

@MainActor
final class SharedContainerWatcher {
    private static let logger = Logger(
        subsystem: "com.dockpops.companion",
        category: "SharedContainerWatcher"
    )

    private let fileManager = FileManager.default
    private let onChange: @MainActor () -> Void

    private var accessSession: SharedContainerAccess.PersistentAccessSession?
    private var containerWatcher: DirectoryWatcher?
    private var popIconsWatcher: DirectoryWatcher?
    private var debounceTask: Task<Void, Never>?
    private var popIconsRetryTask: Task<Void, Never>?

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard accessSession == nil else { return }
        guard SharedContainerAccess.hasStoredBookmark() else { return }

        do {
            let session = try SharedContainerAccess.beginPersistentAccess()
            accessSession = session

            let paths = SharedContainerPaths(containerURL: session.url)
            containerWatcher = try DirectoryWatcher(url: session.url) { [weak self] in
                MainActor.assumeIsolated { [weak self] in
                    self?.handleContainerEvent(paths: paths)
                }
            }
            installPopIconsWatcherIfPossible(at: paths.sharedPopIconsDirectoryURL)
        } catch {
            Self.logger.error("Unable to start shared container watcher: \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        popIconsRetryTask?.cancel()
        popIconsRetryTask = nil
        popIconsWatcher?.cancel()
        popIconsWatcher = nil
        containerWatcher?.cancel()
        containerWatcher = nil
        accessSession?.invalidate()
        accessSession = nil
    }

    private func handleContainerEvent(paths: SharedContainerPaths) {
        scheduleDebouncedRefresh()
        if popIconsWatcher == nil {
            installPopIconsWatcherIfPossible(at: paths.sharedPopIconsDirectoryURL)
        }
    }

    private func installPopIconsWatcherIfPossible(at url: URL) {
        guard popIconsWatcher == nil else { return }

        if !fileManager.fileExists(atPath: url.path) {
            schedulePopIconsRetry(for: url)
            return
        }

        do {
            popIconsWatcher = try DirectoryWatcher(url: url) { [weak self] in
                MainActor.assumeIsolated { [weak self] in
                    self?.scheduleDebouncedRefresh()
                }
            }
        } catch {
            Self.logger.error("Unable to watch PopIcons directory: \(error.localizedDescription, privacy: .public)")
            schedulePopIconsRetry(for: url)
        }
    }

    private func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [onChange] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            onChange()
        }
    }

    private func schedulePopIconsRetry(for url: URL) {
        guard popIconsRetryTask == nil else { return }

        popIconsRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.popIconsRetryTask = nil
            self.installPopIconsWatcherIfPossible(at: url)
        }
    }
}

private final class DirectoryWatcher {
    private let url: URL
    private let source: DispatchSourceFileSystemObject

    init(url: URL, onEvent: @escaping () -> Void) throws {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        self.url = url
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: .main
        )
        source.setEventHandler(handler: onEvent)
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
    }

    func cancel() {
        source.cancel()
    }

    deinit {
        source.cancel()
    }
}
