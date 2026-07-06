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

/// SACRED CODE:
/// The Poplet does NOT touch the App Group itself. Poplet `.app` bundles are
/// ad-hoc signed (generated at runtime), and macOS 26 prompts "...would like
/// to access data from other apps" on every click when an ad-hoc binary uses
/// an App Group entitlement — TCC can't persist consent against a missing
/// team identity.
///
/// Instead the Poplet posts a `DistributedNotificationCenter` request straight
/// to DockPops Main, with the open payload in `userInfo`. DockPops observes
/// the notification on the same name and opens the popover directly. No App
/// Group, no entitlement, no Companion mediation, no LaunchServices flash.
///
/// See `docs/specs/dockpops-main-direct-ipc.md` for the DockPops-side
/// listener contract that pairs with this.
private enum PopletDockPopsIPC {
    /// DistributedNotification name DockPops Main observes. Keep in lockstep
    /// with the DockPops listener registration. (Re-uses the canonical
    /// `com.dockpops.poplet.openRequest` name from Sacred Zone #20; the
    /// previous transport — Darwin notify center + App-Group UserDefaults
    /// payload — is replaced by a single `DistributedNotificationCenter` post
    /// that carries the payload natively in `userInfo`.)
    static let requestNotificationName = "com.dockpops.poplet.openRequest"
}

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
        // (PopletKit's PopletBundleWriter).
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

        // SACRED CODE (revised 2026-05-29 — TCC fix):
        // The Poplet must never read the `group.com.dockpops.shared` App Group
        // container — NOT via the entitlement AND NOT via a hardcoded absolute
        // path. App Group membership is per-binary signature; an ad-hoc Poplet
        // isn't a member, so ANY container read trips the macOS 26 "would like
        // to read data from other apps" prompt on every click (and ad-hoc
        // cdhash churn means granted consent never survives a re-sign/reboot).
        // The earlier note here claiming an absolute-path read is prompt-free
        // was WRONG.
        //
        // What IS allowed: reads of the NON-GATED `~/Applications/DockPops/
        // Icons/` folder, where the generator writes verbatim icon byte-copies.
        // See `PopletLiveIconController.refreshFromSharedContainer` (now reads
        // `Icons/<uuid>.live.png`) and `PopletSharedPaths.iconsDirectoryURL`.

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
        // Poll-on-click: re-read the composite PNG from the shared
        // container before opening the popover. Covers the case where the
        // user edited the Pop in Main while this Poplet was running but
        // Companion was closed (DNC iconUpdated may have been missed by
        // the mirror's file watcher; the disk PNG is the source of truth).
        liveIconController?.refreshFromSharedContainer()

        // Closed-bundle repair on EVERY click. Poplets are .accessory+resident,
        // so applicationDidFinishLaunching fires only once per session — the
        // healer must also run on reopen, otherwise mid-session Pop edits never
        // reach disk and Finder / cold-launch tiles stay stale.
        //
        // TWO-CLICK FIX: route through the controller's healOnClick(), which
        // re-applies the icon AFTER the heal finishes. The log proved the heal
        // takes ~1s and the plate only lifts once applicationIconImage is re-set
        // POST-heal — otherwise that re-set only happened on the *next* click.
        liveIconController?.healOnClick()

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

        // Hot path: DockPops is already running → post the open request as a
        // DistributedNotification with the payload in userInfo. DockPops's
        // listener picks it up and opens the popover directly. Bypasses
        // LaunchServices (no Dock flash in Menu Bar mode) and requires no
        // entitlement on this process (no TCC prompt on ad-hoc bundles).
        //
        // Cold path: DockPops isn't running → fire the legacy URL scheme to
        // wake it. One-time flash on cold launch is the cost of launching
        // DockPops at all and is accepted UX.
        let dockPopsRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == PopletSharedPaths.dockPopsBundleIdentifier
        }

        if dockPopsRunning {
            postOpenPopToDockPops(mouse: mouse)
        } else {
            fireLegacyOpenPopURL(mouse: mouse)
        }
    }

    /// HOT PATH — direct cross-process post to DockPops Main.
    ///
    /// SACRED CODE:
    /// `DistributedNotificationCenter` is the only IPC mechanism that meets
    /// every constraint at once: it carries a payload (`userInfo`), it does
    /// NOT need any entitlement (so an ad-hoc Poplet doesn't trip macOS 26
    /// TCC), and it does NOT go through LaunchServices' GURL Apple Event
    /// (so it doesn't flash the Dock in Menu Bar mode). `distnoted` only
    /// delivers to a *running* app — DockPops cold-start is covered by the
    /// URL fallback in the caller.
    private func postOpenPopToDockPops(mouse: NSPoint) {
        let payload: [String: Any] = [
            "pop": rawPopID,
            "x": Double(mouse.x),
            "y": Double(mouse.y),
            "locked": true,
            "source": "poplet",
            "timestamp": Date().timeIntervalSince1970,
        ]
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(PopletDockPopsIPC.requestNotificationName),
            object: nil,
            userInfo: payload,
            deliverImmediately: true
        )
    }

    /// COLD PATH — DockPops is not running. Use the legacy URL scheme to
    /// wake it. LaunchServices' GURL-event delivery briefly asserts regular
    /// activation on the receiver and produces a Dock flash in Menu Bar mode;
    /// on cold start this is the cost of launching DockPops at all, so we
    /// accept the one-time flash here.
    private func fireLegacyOpenPopURL(mouse: NSPoint) {
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
