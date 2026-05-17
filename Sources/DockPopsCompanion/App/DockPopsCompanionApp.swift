import AppKit
import SwiftUI

@main
struct DockPopsCompanionApp: App {
    @State private var model = CompanionModel()
    @State private var appUpdater = AppUpdater()

    init() {
        // Always open at the default size. Clearing persisted frames also drops
        // stale split-view cruft and any oversized frame saved by older builds.
        Self.clearStaleWindowFrames()
    }

    var body: some Scene {
        Window("DockPops Companion", id: "main") {
            ContentView(model: model)
                // ╔═══════════════════════════════════════════════════════════╗
                // ║ SACRED CODE — window sizing. DO NOT MODIFY without        ║
                // ║ reading this. Touching it has regressed the same bug      ║
                // ║ across releases 1.1 / 1.5 / 1.5.1 / 4.0.                  ║
                // ╠═══════════════════════════════════════════════════════════╣
                // ║ THE BUG: the Companion window reopens absurdly tall —     ║
                // ║ taller than the screen, content stranded in white space.  ║
                // ║                                                           ║
                // ║ ROOT CAUSE: `PopletFinderGridView` wraps an NSCollection- ║
                // ║ View. Left to size itself, an NSViewRepresentable reports ║
                // ║ the collection view's full intrinsic content height as    ║
                // ║ its "ideal" size, and SwiftUI inflates the window to fit  ║
                // ║ every row. Reactive "clamp it back" code loses the race   ║
                // ║ against SwiftUI's per-layout-pass resizing.               ║
                // ║                                                           ║
                // ║ THE FIX — three load-bearing parts, all required:         ║
                // ║  1. `PopletFinderGridView.sizeThatFits` returns the       ║
                // ║     PROPOSED size, never the collection view's intrinsic  ║
                // ║     size. The grid scrolls; it can never inflate anyone.  ║
                // ║  2. The window MINIMUM is the hard `.frame` floor below   ║
                // ║     (`Window.minSize`) — a CONSTANT, never derived from   ║
                // ║     content layout, so refactors cannot drift it.         ║
                // ║  3. `.windowResizability(.contentMinSize)` keeps the      ║
                // ║     window freely resizable UP from that floor.           ║
                // ║                                                           ║
                // ║ The window must stay resizable: on small / scaled        ║
                // ║ displays the user has to be able to shrink it.            ║
                // ║                                                           ║
                // ║ RULES — keep this bug dead:                               ║
                // ║  • Keep `PopletFinderGridView.sizeThatFits`. Without it   ║
                // ║    the collection view inflates the window again.         ║
                // ║  • The window min must stay a CONSTANT `.frame` floor.    ║
                // ║    Never let it derive from title/grid measurements.      ║
                // ║  • Do NOT add reactive frame-clamping band-aids. If the   ║
                // ║    window grows wrong, parts 1–3 above are the fix.       ║
                // ║  • Pop content scrolls inside the grid — never size the   ║
                // ║    window to the Pop count.                               ║
                // ╚═══════════════════════════════════════════════════════════╝
                .frame(
                    minWidth: CompanionLayout.Window.minSize.width,
                    maxWidth: .infinity,
                    minHeight: CompanionLayout.Window.minSize.height,
                    maxHeight: .infinity
                )
        }
        .defaultSize(
            width: CompanionLayout.Window.defaultSize.width,
            height: CompanionLayout.Window.defaultSize.height
        )
        .windowResizability(.contentMinSize) // SACRED — see block above.
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    appUpdater.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
            }
        }
    }

    /// SwiftUI/AppKit persist an `NSWindow Frame …` entry per scene. Clearing it
    /// on launch means the window always opens at `defaultSize` (clamped to the
    /// screen) instead of a possibly-oversized saved frame, and also removes
    /// obsolete split-view keys left by earlier layouts.
    private static func clearStaleWindowFrames() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("NSWindow Frame ")
            || key.hasPrefix("NSSplitView Subview Frames ") {
            defaults.removeObject(forKey: key)
        }
    }
}
