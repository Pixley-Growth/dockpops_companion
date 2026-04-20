import AppKit
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

enum SharedContainerAccessError: LocalizedError, Equatable {
    case permissionRequired
    case userCancelled
    case invalidSelection
    case unreadableBookmark

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Allow the DockPops shared folder so the companion can sync your Pops."
        case .userCancelled:
            return "Folder access was cancelled."
        case .invalidSelection:
            return "The DockPops folder should already be open. If it is not, choose group.com.dockpops.shared and click Allow."
        case .unreadableBookmark:
            return "The saved DockPops permission needs to be refreshed."
        }
    }
}

enum SharedContainerAccess {
    private enum DefaultsKey {
        static let bookmarkData = "sharedContainerBookmarkData"
    }

    static func hasStoredBookmark() -> Bool {
        UserDefaults.standard.data(forKey: DefaultsKey.bookmarkData) != nil
    }

    static func clearStoredBookmark() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.bookmarkData)
    }

    @MainActor
    static func requestAccess() throws -> URL {
        let panel = NSOpenPanel()
        let expectedURL = AppPaths.expectedGroupContainerURL
        let opensExactFolder = FileManager.default.fileExists(atPath: expectedURL.path)

        panel.title = "Allow DockPops Access"
        panel.message = opensExactFolder
            ? "The DockPops shared folder is already open. Click Allow so the companion can sync your Pops."
            : "Choose the DockPops shared folder so the companion can sync your Pops."
        panel.prompt = "Allow"
        panel.directoryURL = opensExactFolder ? expectedURL : expectedURL.deletingLastPathComponent()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true

        guard panel.runModal() == .OK else {
            throw SharedContainerAccessError.userCancelled
        }

        guard let selectedURL = panel.url?.standardizedFileURL else {
            throw SharedContainerAccessError.userCancelled
        }

        guard isExpectedContainerURL(selectedURL) else {
            throw SharedContainerAccessError.invalidSelection
        }

        let bookmarkData = try selectedURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(bookmarkData, forKey: DefaultsKey.bookmarkData)
        return selectedURL
    }

    static func withAccess<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let url = try resolvedContainerURL()
        let startedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if startedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try body(url)
    }

    private static func resolvedContainerURL() throws -> URL {
        guard let bookmarkData = UserDefaults.standard.data(forKey: DefaultsKey.bookmarkData) else {
            throw SharedContainerAccessError.permissionRequired
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ).standardizedFileURL

            guard isExpectedContainerURL(url) else {
                clearStoredBookmark()
                throw SharedContainerAccessError.invalidSelection
            }

            if isStale {
                let refreshedBookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(refreshedBookmark, forKey: DefaultsKey.bookmarkData)
            }

            return url
        } catch let error as SharedContainerAccessError {
            throw error
        } catch {
            clearStoredBookmark()
            throw SharedContainerAccessError.unreadableBookmark
        }
    }

    private static func isExpectedContainerURL(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        if standardized.path == AppPaths.expectedGroupContainerURL.standardizedFileURL.path {
            return true
        }

        return standardized.lastPathComponent == AppPaths.appGroupIdentifier
    }
}
