import Foundation

/// In-place directory mirroring used by the Poplet install step (§3.2).
///
/// The top-level `destination` directory is **never removed or recreated**, so
/// its inode is preserved across the update — that is what keeps the Dock pin
/// alive when a Poplet bundle is regenerated. Inner files are replaced and
/// stale ones removed. Pure (takes a `FileManager`) so the inode-stability
/// guarantee is unit-testable without the rest of `PopletSyncService`.
enum DirectoryInPlaceSync {
    static func sync(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        let sourceNames = try fileManager.contentsOfDirectory(atPath: source.path)
        let destinationNames = (try? fileManager.contentsOfDirectory(atPath: destination.path)) ?? []
        let sourceNameSet = Set(sourceNames)

        // Remove stale destination entries that are gone from source.
        for name in destinationNames where !sourceNameSet.contains(name) {
            try fileManager.removeItem(at: destination.appending(path: name))
        }

        // Copy / recurse source entries into destination.
        for name in sourceNames {
            let sourceItem = source.appending(path: name)
            let destinationItem = destination.appending(path: name)

            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: sourceItem.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try sync(from: sourceItem, to: destinationItem, fileManager: fileManager)
            } else {
                if fileManager.fileExists(atPath: destinationItem.path) {
                    try fileManager.removeItem(at: destinationItem)
                }
                try fileManager.copyItem(at: sourceItem, to: destinationItem)
            }
        }
    }
}
