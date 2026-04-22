import Foundation

enum AppPaths {
    static let dockPopsBundleIdentifier = "com.dockpops.app"
    static let appGroupIdentifier = "group.com.dockpops.shared"

    static let groupContainersRootURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Group Containers", directoryHint: .isDirectory)

    static let expectedGroupContainerURL = groupContainersRootURL
        .appending(path: appGroupIdentifier, directoryHint: .isDirectory)

    static let companionSupportDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/DockPops Companion", directoryHint: .isDirectory)

    static let dockPopsContainerDataURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Containers", directoryHint: .isDirectory)
        .appending(path: dockPopsBundleIdentifier, directoryHint: .isDirectory)
        .appending(path: "Data", directoryHint: .isDirectory)

    static let dockPopsContainerPreferencesDirectoryURL = dockPopsContainerDataURL
        .appending(path: "Library/Preferences", directoryHint: .isDirectory)

    static let dockPopsContainerPreferencesURL = dockPopsContainerPreferencesDirectoryURL
        .appending(path: "\(dockPopsBundleIdentifier).plist")

    static let dockPopsLegacyPreferencesURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Preferences", directoryHint: .isDirectory)
        .appending(path: "\(dockPopsBundleIdentifier).plist")

    static let sharedContainerBookmarkURL = companionSupportDirectoryURL
        .appending(path: "shared-container.bookmark")

    /// SACRED CODE:
    /// This mirror is the only live-icon surface that poplets are allowed to
    /// read directly. The companion owns the security-scoped access to
    /// DockPops' protected shared container and mirrors `PopIcons/*.png` here.
    ///
    /// If a future edit points a poplet back at `group.com.dockpops.shared` or
    /// DockPops' private preferences container, we will reintroduce repeated
    /// permission prompts and stale/blue generic Dock icons.
    static let popletLiveIconsDirectoryURL = companionSupportDirectoryURL
        .appending(path: "PopletLiveIcons", directoryHint: .isDirectory)

    static let popletRegistryURL = companionSupportDirectoryURL
        .appending(path: "poplet-registry.json")

    static let popletsDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Applications/DockPops", directoryHint: .isDirectory)
}
