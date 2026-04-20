import Foundation

enum PopletSharedPaths {
    static let groupIdentifier = "group.com.dockpops.shared"

    static var popIconsDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers", directoryHint: .isDirectory)
            .appending(path: groupIdentifier, directoryHint: .isDirectory)
            .appending(path: "PopIcons", directoryHint: .isDirectory)
    }

    static func popIconURL(for popID: UUID) -> URL {
        popIconsDirectoryURL.appending(path: "\(popID.uuidString).png")
    }
}
