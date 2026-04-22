import AppKit
import Foundation

@MainActor
@main
enum DockPopsPopletMain {
    private static let delegate = DockPopsPopletDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class DockPopsPopletDelegate: NSObject, NSApplicationDelegate {
    private let rawPopID = (Bundle.main.infoDictionary?["DockPopsTargetPopID"] as? String) ?? ""
    private var liveIconController: PopletLiveIconController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let popID = UUID(uuidString: rawPopID) else {
            NSApp.terminate(nil)
            return
        }

        installMenu()

        // SACRED CODE:
        // Poplets must never reopen shared-container access on launch. They
        // consume only the companion-managed mirror so they stay prompt-free
        // and so live icon regressions cannot sneak back in through a "quick"
        // raw path fallback.

        // Method B — mirror the shared pop composite onto the running app's
        // Dock tile via NSApp.applicationIconImage using the companion's
        // mirrored live-icon cache. Never touches the bundle on disk, so it
        // cannot invalidate the bundle signature.
        let live = PopletLiveIconController(popID: popID)
        live.start()
        liveIconController = live

        // Method C1 — if the on-disk AppIcon.icns is older than the mirrored
        // live icon PNG, rebuild it, re-sign the bundle, and nudge Launch
        // Services so Finder / Dock-at-rest pick up the fresh icon. Runs
        // detached so a slow iconutil/codesign doesn't delay openPop().
        let healer = PopletBundleIconHealer(
            popID: popID,
            bundleURL: Bundle.main.bundleURL
        )
        Task.detached(priority: .utility) {
            await healer.healIfStale()
        }

        openPop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        liveIconController?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPop()
        return false
    }

    @objc
    private func openPopFromMenu(_ sender: Any?) {
        openPop()
    }

    @objc
    private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func openPop() {
        let mouse = NSEvent.mouseLocation
        var components = URLComponents()
        components.scheme = "dockpops"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "pop", value: rawPopID),
            URLQueryItem(name: "x", value: String(Double(mouse.x))),
            URLQueryItem(name: "y", value: String(Double(mouse.y))),
            URLQueryItem(name: "locked", value: "1"),
        ]

        guard let url = components.url else { return }
        _ = NSWorkspace.shared.open(url)
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "DockPops Pop"

        let openTitle = "Open \(appName)"
        let openItem = NSMenuItem(
            title: openTitle,
            action: #selector(openPopFromMenu(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        appMenu.addItem(openItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}
