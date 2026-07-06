import Foundation

/// SACRED CODE — UPDATED 2026-05-29 (TCC fix):
///
/// The Poplet binary is **ad-hoc signed** and is therefore NOT a member of the
/// `group.com.dockpops.shared` App Group (membership is per-binary signature,
/// not inherited from the generator). On macOS 26 ANY read of that App Group
/// container — even by hardcoded absolute path — trips the "would like to read
/// data from other apps" prompt on every click, and ad-hoc cdhash churn means
/// the granted consent never survives a re-sign/reboot.
///
/// THE FIX: the Poplet reads its icons ONLY from the **non-gated**
/// `~/Applications/DockPops/Icons/` folder, never from the App Group container:
///   • `PopletLiveIconController` reads `<uuid>.live.png` (256² runtime variant)
///     from `iconsDirectoryURL` for the running tile.
///   • `PopletBundleIconHealer` reads `<uuid>.png` (master) from the same
///     folder for closed-bundle repair.
/// The generator (Companion / Complete) writes verbatim byte-copies of those
/// PNGs into `Icons/` at sync time. Do NOT point a Poplet reader back at the
/// App Group container or give the Poplet an App Group entitlement — that is
/// exactly what re-introduces the prompt.
///
/// The Companion-internal mirror in `…/Application Support/DockPops Companion/
/// PopletLiveIcons/` (`mirroredPopIconsDirectoryURL`) is non-gated. WATCH TARGET
/// (2026-07-06, two-click fix): Poplets now WATCH `iconsDirectoryURL`
/// (`~/Applications/DockPops/Icons/`) — the non-gated folder BOTH MAIN and the
/// generator write — instead of the Companion-only mirror above. Watching Icons/
/// lets a resident Poplet proactively heal its bundle on a MAIN edit even when the
/// COMPANION is CLOSED (the mirror is written only while the Companion runs, which
/// was the "two clicks with Companion closed" bug). The mirror stays a permitted
/// non-gated fallback source, just no longer the watch target.
enum PopletSharedPaths {
    static let dockPopsBundleIdentifier = "com.dockpops.app"

    static var companionSupportDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/DockPops Companion", directoryHint: .isDirectory)
    }

    static var mirroredPopIconsDirectoryURL: URL {
        companionSupportDirectoryURL.appending(path: "PopletLiveIcons", directoryHint: .isDirectory)
    }

    static func mirroredPopIconURL(for popID: UUID) -> URL {
        mirroredPopIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
    }

    /// `~/Applications/DockPops/` — where the generated Poplet `.app` bundles
    /// live (channel-agnostic, shared by Complete + Companion).
    static var popletsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications/DockPops", directoryHint: .isDirectory)
    }

    /// `~/Applications/DockPops/Icons/` — the **non-gated** folder the Poplet
    /// reads its icons from (the load-bearing surface of the TCC fix). Mirrors
    /// the main repo's `PopletPaths.iconsDirectoryURL` so both channels' Poplets
    /// read byte-identical icons.
    static var iconsDirectoryURL: URL {
        popletsDirectoryURL.appending(path: "Icons", directoryHint: .isDirectory)
    }

    /// Per-Pop master PNG in the non-gated Icons folder (closed-bundle icon
    /// source — verbatim byte-copy of the App Group `<uuid>.png` sibling).
    static func iconMasterURL(for popID: UUID) -> URL {
        iconsDirectoryURL.appending(path: "\(popID.uuidString).png")
    }

    /// Per-Pop 256² live PNG in the non-gated Icons folder (running-tile icon
    /// source — verbatim byte-copy of the App Group `<uuid>.live.png` sibling).
    static func iconLiveURL(for popID: UUID) -> URL {
        iconsDirectoryURL.appending(path: "\(popID.uuidString).live.png")
    }

    /// Non-gated live-icon folders a Poplet may watch/read: the canonical
    /// `~/Applications/DockPops/Icons/` (written by BOTH MAIN and the generator)
    /// and the Companion mirror. The FORBIDDEN target is the
    /// `group.com.dockpops.shared` App Group container — reading it trips the
    /// macOS 26 per-click TCC prompt on an ad-hoc Poplet. Neither folder here is
    /// gated, so both are safe.
    private static var nonGatedLiveIconDirectoryPaths: [String] {
        [iconsDirectoryURL, mirroredPopIconsDirectoryURL]
            .map { $0.standardizedFileURL.path }
    }

    static func assertUsesNonGatedLiveIconsDirectory(
        _ url: URL,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(
            nonGatedLiveIconDirectoryPaths.contains(url.standardizedFileURL.path),
            """
            SACRED CODE: Poplets must watch/read live icons from a NON-GATED folder — \
            \(iconsDirectoryURL.path) or \(mirroredPopIconsDirectoryURL.path) — never the \
            group.com.dockpops.shared App Group container (per-click TCC prompt).
            """,
            file: file,
            line: line
        )
    }

    static func assertUsesNonGatedLiveIconFile(
        _ url: URL,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(
            nonGatedLiveIconDirectoryPaths.contains(
                url.deletingLastPathComponent().standardizedFileURL.path
            ),
            """
            SACRED CODE: Poplet live icon files must live under a NON-GATED folder — \
            \(iconsDirectoryURL.path) or \(mirroredPopIconsDirectoryURL.path). If this \
            fires, someone wired the poplet to the gated App Group container.
            """,
            file: file,
            line: line
        )
    }
}
