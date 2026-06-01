import AppKit
import Foundation

/// Production `PopletTerminating` for `PopletRenameCore`. Terminates the
/// resident `.accessory` Poplet so its `.app` directory isn't "open" when we
/// rename it. Matches on the exact Poplet bundle id
/// (`com.dockpops.poplet.<uuid>` — the unified id the generator stamps, see
/// `PopletRenameCore.popletBundleIDPrefix`) so no unrelated process is touched.
/// Stateless → trivially `Sendable`.
struct RunningApplicationPopletTerminator: PopletTerminating {
    func terminateRunningPoplet(bundleID: String, timeout: Duration) -> Bool {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard !apps.isEmpty else { return false }

        for app in apps { app.terminate() }

        // Bounded poll for exit. `sync()` runs off the main actor on a detached
        // utility task, so a short blocking wait here is acceptable.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if apps.allSatisfy(\.isTerminated) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Resident `.accessory` Poplets normally quit promptly; force any
        // stragglers so the rename isn't blocked by a lingering "open" lock.
        for app in apps where !app.isTerminated { app.forceTerminate() }
        return true
    }
}
