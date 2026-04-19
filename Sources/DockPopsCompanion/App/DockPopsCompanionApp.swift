import AppKit
import SwiftUI

private let launchWindowSize = NSSize(width: 640, height: 620)

@main
struct DockPopsCompanionApp: App {
    @State private var model = CompanionModel()

    var body: some Scene {
        Window("DockPops Companion", id: "main") {
            ContentView(model: model)
                .background(WindowLaunchSizingView(size: launchWindowSize))
        }
        .defaultSize(width: launchWindowSize.width, height: launchWindowSize.height)
    }
}

private struct WindowLaunchSizingView: NSViewRepresentable {
    let size: NSSize

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.applyLaunchSizeIfNeeded(to: view.window, size: size)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.applyLaunchSizeIfNeeded(to: nsView.window, size: size)
        }
    }

    @MainActor
    final class Coordinator {
        private var sizedWindowNumber: Int?

        func applyLaunchSizeIfNeeded(to window: NSWindow?, size: NSSize) {
            guard let window else { return }
            guard sizedWindowNumber != window.windowNumber else { return }

            sizedWindowNumber = window.windowNumber
            window.setContentSize(size)
            window.center()
        }
    }
}
