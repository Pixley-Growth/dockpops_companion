import Foundation

/// SACRED CODE — UPDATED 2026-05-21:
///
/// The mirror in `~/Library/Application Support/DockPops Companion/PopletLiveIcons/`
/// is a Companion-internal cache. It is NOT the Poplet's source of truth.
///
/// Two Poplet read paths have been moved off the mirror:
///   • `PopletLiveIconController` reads the canonical `<uuid>.live.png`
///     (256² runtime variant) directly from
///     `~/Library/Group Containers/group.com.dockpops.shared/PopIcons/` for
///     the running tile.
///   • `PopletBundleIconHealer` reads the canonical `<uuid>.png` (1024²
///     master) from the same directory for closed-bundle repair.
///
/// Both reads are by hardcoded ABSOLUTE PATH (POSIX permissions only, no
/// entitlement, no TCC prompt). The mirror is kept up to date by Companion
/// for any Companion-side feature that wants a project-managed copy, but it
/// is NOT load-bearing for Poplet icon correctness anymore — Companion is a
/// foreground app that is closed most of the time, so the mirror lags reality.
///
/// Do not point Poplet readers at this mirror. If you do, mid-session Pop
/// edits won't reach the Poplet until the user next opens Companion, which
/// they basically never do.
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

    static func assertUsesMirroredLiveIconsDirectory(
        _ url: URL,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(
            url.standardizedFileURL.path == mirroredPopIconsDirectoryURL.standardizedFileURL.path,
            """
            SACRED CODE: Poplets must read live icons only from the companion mirror at \
            \(mirroredPopIconsDirectoryURL.path). Do not point them back at DockPops' \
            protected shared container.
            """,
            file: file,
            line: line
        )
    }

    static func assertUsesMirroredLiveIconFile(
        _ url: URL,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        precondition(
            url.deletingLastPathComponent().standardizedFileURL.path
                == mirroredPopIconsDirectoryURL.standardizedFileURL.path,
            """
            SACRED CODE: Poplet live icon files must live under \
            \(mirroredPopIconsDirectoryURL.path). If this fires, someone wired \
            the poplet back to the wrong icon source.
            """,
            file: file,
            line: line
        )
    }
}
