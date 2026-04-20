import AppKit
import SwiftUI

@main
struct DockPopsCompanionApp: App {
    @State private var model = CompanionModel()
    @State private var appUpdater = AppUpdater()

    init() {
        WindowFrameResetter.clearInvalidSavedFrame(for: "main", launchSize: CompanionLayout.Window.launchSize)
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
        .windowResizability(.contentSize)
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

private enum WindowFrameResetter {
    /// SwiftUI stores restored window frames in UserDefaults under `NSWindow Frame <id>`.
    /// Older oversized layouts can leave behind absurd values that keep reopening long
    /// after the content has been simplified, so we discard obviously invalid frames.
    static func clearInvalidSavedFrame(for windowID: String, launchSize: NSSize) {
        let key = "NSWindow Frame \(windowID)"
        guard let savedFrame = UserDefaults.standard.string(forKey: key) else { return }

        let components = savedFrame
            .split(whereSeparator: \.isWhitespace)
            .compactMap { Double($0) }

        guard components.count >= 4 else { return }

        let savedWidth = components[2]
        let savedHeight = components[3]
        let visibleScreenHeight = components.count >= 8 ? components[7] : 0

        let widthIsAbsurd = savedWidth > launchSize.width * 1.8
        let heightIsAbsurd = savedHeight > launchSize.height * 1.8
        let tallerThanVisibleScreen = visibleScreenHeight > 0 && savedHeight > visibleScreenHeight * 0.95

        guard widthIsAbsurd || heightIsAbsurd || tallerThanVisibleScreen else { return }
        UserDefaults.standard.removeObject(forKey: key)
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

            sizedWindowNumber = window.windowNumber
            apply(window: window, size: size)

            // State restoration can reassert an old frame on the next run loop turn.
            // Reapply once more after the window is fully attached so launch size wins.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.apply(window: window, size: size)
            }
        }

        private func apply(window: NSWindow, size: NSSize) {
            window.isRestorable = false
            UserDefaults.standard.removeObject(forKey: "NSWindow Frame main")
            window.setContentSize(size)
            window.center()
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
