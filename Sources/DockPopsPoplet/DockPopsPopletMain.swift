import AppKit
import Foundation

// EXPERIMENT outcome — "accessory, resident" Poplets (2026-05-19)
//
// Goal: stop Poplets from occupying a CMD+TAB slot, without making the Dock
// icon bounce on every click.
//
// What we learned: the Dock bounce is the *launch* animation — it plays only
// while a non-running app starts up. A resident app reopens silently. So a
// quit-on-click Poplet bounces on every click (every click is a cold launch).
//
// The fix is the activation policy, not the lifetime. `.accessory` removes the
// CMD+TAB entry whether or not the app is running, so the Poplet can stay
// resident: no CMD+TAB slot, and no bounce after the first cold launch.

@MainActor
@main
enum DockPopsPopletMain {
    private static let delegate = DockPopsPopletDelegate()

    static func main() {
        let app = NSApplication.shared
        // SACRED CODE:
        // Poplets MUST launch `.accessory` and stay resident. `.regular` puts
        // every poplet in CMD+TAB — the #1 user complaint. Quitting on click
        // instead of staying resident makes the Dock tile bounce on every
        // click (a cold launch bounces; a resident reopen does not).
        // `.accessory` + resident is the only combination with neither.
        // Keep this in lockstep with `LSUIElement` in the generated Info.plist
        // (PopletSyncService.writePopletBundle).
        app.setActivationPolicy(.accessory)
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

        let isDefaultLaunch = (notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool) ?? true
        if isDefaultLaunch {
            openPop()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        liveIconController?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPop()
        return false
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        prepareDockPopsForDrop()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            forwardDroppedItemsToDockPops(urls)
        }
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
            // A Poplet is a real Dock icon, not a Siri/Spotlight shortcut.
            // `source=poplet` tells DockPops to anchor the popover at the
            // supplied coordinates even when DockPops runs in Menu Bar mode
            // — otherwise the popover wrongly opens at the menu bar.
            URLQueryItem(name: "source", value: "poplet"),
        ]

        guard let url = components.url else { return }
        // Deliver the URL WITHOUT launch-activating DockPops. A plain open(_:)
        // fronts DockPops as the URL handler — that triggers the Dock "make
        // space" animation and pulls the organizer window forward. DockPops
        // shows the Poplet popover as a background utility; it must not steal
        // foreground focus.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration, completionHandler: nil)
    }

    private func prepareDockPopsForDrop() {
        var components = URLComponents()
        components.scheme = "dockpops"
        components.host = "prepare-poplet-drop"
        components.queryItems = [
            URLQueryItem(name: "pop", value: rawPopID),
        ]

        guard let url = components.url else { return }
        _ = NSWorkspace.shared.open(url)
    }

    private func forwardDroppedItemsToDockPops(_ urls: [URL]) {
        guard
            let dockPopsURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: PopletSharedPaths.dockPopsBundleIdentifier
            )
        else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            urls,
            withApplicationAt: dockPopsURL,
            configuration: configuration
        )
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
