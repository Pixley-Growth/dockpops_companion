import Foundation

struct SharedContainerPaths {
    let containerURL: URL

    var shortcutGroupsURL: URL {
        containerURL.appending(path: "shortcut-groups.json")
    }

    var sharedPopIconsDirectoryURL: URL {
        containerURL.appending(path: "PopIcons", directoryHint: .isDirectory)
    }
}
