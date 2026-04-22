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

    private enum BookmarkSource {
        case defaults
        case file
    }

    final class PersistentAccessSession {
        let url: URL

        private var startedAccess: Bool

        fileprivate init(url: URL, startedAccess: Bool) {
            self.url = url
            self.startedAccess = startedAccess
        }

        func invalidate() {
            guard startedAccess else { return }
            url.stopAccessingSecurityScopedResource()
            startedAccess = false
        }

        deinit {
            invalidate()
        }
    }

    static func hasStoredBookmark() -> Bool {
        UserDefaults.standard.data(forKey: DefaultsKey.bookmarkData) != nil
            || FileManager.default.fileExists(atPath: AppPaths.sharedContainerBookmarkURL.path)
    }

    static func clearStoredBookmark() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.bookmarkData)
        try? FileManager.default.removeItem(at: AppPaths.sharedContainerBookmarkURL)
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
        try storeBookmarkData(bookmarkData)
        return selectedURL
    }

    static func withAccess<Result>(_ body: (URL) throws -> Result) throws -> Result {
        let resolution = try resolvedContainerURL()
        let url = resolution.url
        let startedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if startedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if resolution.isStale {
            try refreshBookmark(for: url)
        }
        return try body(url)
    }

    static func beginPersistentAccess() throws -> PersistentAccessSession {
        let resolution = try resolvedContainerURL()
        let url = resolution.url
        let startedAccess = url.startAccessingSecurityScopedResource()
        if resolution.isStale {
            try refreshBookmark(for: url)
        }
        return PersistentAccessSession(url: url, startedAccess: startedAccess)
    }

    private struct ResolvedBookmark {
        let url: URL
        let isStale: Bool
    }

    private static func resolvedContainerURL() throws -> ResolvedBookmark {
        let storedBookmark = try loadStoredBookmarkData()
        let bookmarkData = storedBookmark.data
        let needsMirrorUpdate =
            storedBookmark.source == .file
            || UserDefaults.standard.data(forKey: DefaultsKey.bookmarkData) != bookmarkData
            || !FileManager.default.fileExists(atPath: AppPaths.sharedContainerBookmarkURL.path)

        if needsMirrorUpdate {
            try storeBookmarkData(bookmarkData)
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

            return ResolvedBookmark(url: url, isStale: isStale)
        } catch let error as SharedContainerAccessError {
            throw error
        } catch {
            clearStoredBookmark()
            throw SharedContainerAccessError.unreadableBookmark
        }
    }

    private static func refreshBookmark(for url: URL) throws {
        let refreshedBookmark = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try storeBookmarkData(refreshedBookmark)
    }

    private static func loadStoredBookmarkData() throws -> (data: Data, source: BookmarkSource) {
        if let bookmarkData = UserDefaults.standard.data(forKey: DefaultsKey.bookmarkData) {
            return (bookmarkData, .defaults)
        }

        if let bookmarkData = try? Data(contentsOf: AppPaths.sharedContainerBookmarkURL) {
            return (bookmarkData, .file)
        }

        throw SharedContainerAccessError.permissionRequired
    }

    private static func storeBookmarkData(_ bookmarkData: Data) throws {
        UserDefaults.standard.set(bookmarkData, forKey: DefaultsKey.bookmarkData)
        try FileManager.default.createDirectory(
            at: AppPaths.companionSupportDirectoryURL,
            withIntermediateDirectories: true
        )
        try bookmarkData.write(to: AppPaths.sharedContainerBookmarkURL, options: .atomic)
    }

    private static func isExpectedContainerURL(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        if standardized.path == AppPaths.expectedGroupContainerURL.standardizedFileURL.path {
            return true
        }

        return standardized.lastPathComponent == AppPaths.appGroupIdentifier
    }
}
