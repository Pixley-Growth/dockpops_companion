import Foundation

/// SACRED CODE:
/// Poplets are intentionally cut off from DockPops' protected shared container
/// and private preferences container. They may read only from the companion's
/// mirrored live-icon cache in Application Support.
///
/// Do not add raw `group.com.dockpops.shared` or DockPops prefs paths back to
/// this file unless you want to reintroduce repeated permission prompts and
/// "why did all the icons turn generic blue?" regressions.
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
