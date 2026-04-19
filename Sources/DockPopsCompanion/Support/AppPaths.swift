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

    static let popletRegistryURL = companionSupportDirectoryURL
        .appending(path: "poplet-registry.json")

    static let popletsDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Applications/DockPops", directoryHint: .isDirectory)
}
