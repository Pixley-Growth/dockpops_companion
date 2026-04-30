import AppKit
import SwiftUI

@main
struct DockPopsCompanionApp: App {
    @NSApplicationDelegateAdaptor(DockPopsCompanionAppDelegate.self) private var appDelegate
    @State private var model = CompanionModel()
    @State private var appUpdater = AppUpdater()

    init() {
        WindowFrameResetter.clearSavedWindowFrames()
    }

    var body: some Scene {
        configuredWindowScene
    }

    private var configuredWindowScene: some Scene {
        Window("DockPops Companion", id: "main") {
            ContentView(model: model)
                .background(WindowLaunchSizingView(size: CompanionLayout.Window.launchSize))
        }
        .defaultSize(
            width: CompanionLayout.Window.launchSize.width,
            height: CompanionLayout.Window.launchSize.height
        )
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appUpdater.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
            }
        }
    }
}

private final class DockPopsCompanionAppDelegate: NSObject, NSApplicationDelegate {
    private var windowObserver: NSObjectProtocol?
    private var launchSizingTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let window = notification.object as? NSWindow else { return }
            Task { @MainActor in
                WindowFrameResetter.configure(
                    to: window,
                    requireMainWindowMatch: true,
                    resizeMode: .ifOutsideBounds
                )
            }
        }

        launchSizingTask = Task { @MainActor in
            for delay in [0, 100_000_000, 400_000_000, 1_000_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay))
                }
                NSApplication.shared.windows.forEach { window in
                    WindowFrameResetter.configure(
                        to: window,
                        requireMainWindowMatch: true,
                        resizeMode: .launchSize
                    )
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchSizingTask?.cancel()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }
}

private enum WindowFrameResetter {
    enum ResizeMode {
        case launchSize
        case ifOutsideBounds
    }

    /// This utility window should always start fresh. SwiftUI/AppKit can store
    /// frames under more than one `NSWindow Frame ...` key across scene changes,
    /// so clear the whole app-domain set rather than guessing the current id.
    static func clearSavedWindowFrames() {
        UserDefaults.standard
            .dictionaryRepresentation()
            .keys
            .filter { $0.hasPrefix("NSWindow Frame ") }
            .forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    @MainActor
    @discardableResult
    static func configure(
        to window: NSWindow,
        requireMainWindowMatch: Bool,
        resizeMode: ResizeMode
    ) -> Bool {
        guard !requireMainWindowMatch || isMainCompanionWindow(window) else { return false }

        window.isRestorable = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.titlebarAppearsTransparent = false
        window.contentMinSize = CompanionLayout.Window.launchSize
        window.contentMaxSize = CompanionLayout.Window.maximumContentSize
        window.contentView?.wantsLayer = true
        window.contentView?.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        clearSavedWindowFrames()

        let contentSize = window.contentLayoutRect.size
        let targetSize: NSSize

        switch resizeMode {
        case .launchSize:
            targetSize = CompanionLayout.Window.launchSize
        case .ifOutsideBounds:
            let minSize = CompanionLayout.Window.launchSize
            let maxSize = CompanionLayout.Window.maximumContentSize
            let widthIsOutsideBounds = contentSize.width < minSize.width || contentSize.width > maxSize.width
            let heightIsOutsideBounds = contentSize.height < minSize.height || contentSize.height > maxSize.height

            guard widthIsOutsideBounds || heightIsOutsideBounds else { return true }
            targetSize = NSSize(
                width: min(max(contentSize.width, minSize.width), maxSize.width),
                height: min(max(contentSize.height, minSize.height), maxSize.height)
            )
        }

        window.setContentSize(targetSize)
        if resizeMode == .launchSize {
            window.center()
        }
        return true
    }

    @MainActor
    private static func isMainCompanionWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "main" || window.title == "DockPops Companion"
    }
}

private struct WindowLaunchSizingView: NSViewRepresentable {
    let size: NSSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowSizingProbeView()
        view.onWindowAvailable = { window in
            context.coordinator.applyLaunchSizeIfNeeded(to: window, size: size)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let probeView = nsView as? WindowSizingProbeView {
            probeView.onWindowAvailable = { window in
                context.coordinator.applyLaunchSizeIfNeeded(to: window, size: size)
            }
        }
        context.coordinator.applyLaunchSizeIfNeeded(to: nsView.window, size: size)
    }

    @MainActor
    final class Coordinator {
        private var sizedWindowNumber: Int?

        /// SwiftUI's defaultSize is not authoritative once the system has a saved
        /// frame for the scene. Clamp the first live window frame exactly once so
        /// stale restored sizes do not survive layout refactors.
        func applyLaunchSizeIfNeeded(to window: NSWindow?, size: NSSize) {
            guard let window else { return }
            guard sizedWindowNumber != window.windowNumber else { return }

            guard apply(window: window) else { return }
            sizedWindowNumber = window.windowNumber

            // State restoration can reassert an old frame on the next run loop turn.
            // Reapply once more after the window is fully attached so launch size wins.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                _ = self.apply(window: window)
            }
        }

        private func apply(window: NSWindow) -> Bool {
            WindowFrameResetter.configure(
                to: window,
                requireMainWindowMatch: false,
                resizeMode: .launchSize
            )
        }
    }
}

private final class WindowSizingProbeView: NSView {
    var onWindowAvailable: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowAvailable?(window)
    }
}
