import XCTest

/// Verifies the §3.2 invariant the Dock pin depends on: regenerating a Poplet
/// updates its `.app` contents WITHOUT changing the bundle directory's inode.
/// DirectoryInPlaceSync.swift is compiled into this target (see project.yml).
final class DirectoryInPlaceSyncTests: XCTestCase {

    private var scratch: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = fm.temporaryDirectory.appending(path: "DirInPlaceSync-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: scratch)
        try super.tearDownWithError()
    }

    private func inode(of url: URL) throws -> UInt64 {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }

    private func makeBundle(at url: URL, executable: String, extra: [String: String] = [:]) throws {
        let contents = url.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try executable.write(to: macOS.appending(path: "Poplet"), atomically: true, encoding: .utf8)
        try "<plist/>".write(to: contents.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
        for (name, value) in extra {
            try value.write(to: url.appending(path: name), atomically: true, encoding: .utf8)
        }
    }

    func testPreservesDestinationInode() throws {
        let dest = scratch.appending(path: "Work.app")
        let staging = scratch.appending(path: ".staging.app")
        try makeBundle(at: dest, executable: "v1")
        try makeBundle(at: staging, executable: "v2")

        let before = try inode(of: dest)
        try DirectoryInPlaceSync.sync(from: staging, to: dest, fileManager: fm)
        let after = try inode(of: dest)

        XCTAssertEqual(before, after, "The .app directory inode must survive an in-place update (Dock pin)")
    }

    func testReplacesInnerFileContents() throws {
        let dest = scratch.appending(path: "Work.app")
        let staging = scratch.appending(path: ".staging.app")
        try makeBundle(at: dest, executable: "old")
        try makeBundle(at: staging, executable: "new")

        try DirectoryInPlaceSync.sync(from: staging, to: dest, fileManager: fm)

        let executable = try String(
            contentsOf: dest.appending(path: "Contents/MacOS/Poplet"), encoding: .utf8
        )
        XCTAssertEqual(executable, "new")
    }

    func testRemovesStaleEntriesNotInSource() throws {
        let dest = scratch.appending(path: "Work.app")
        let staging = scratch.appending(path: ".staging.app")
        // Destination carries a leftover Finder "Icon\r" file + a stale _CodeSignature.
        try makeBundle(at: dest, executable: "v1", extra: ["Icon\r": "x"])
        try fm.createDirectory(
            at: dest.appending(path: "Contents/_CodeSignature"), withIntermediateDirectories: true
        )
        try makeBundle(at: staging, executable: "v1")

        try DirectoryInPlaceSync.sync(from: staging, to: dest, fileManager: fm)

        XCTAssertFalse(
            fm.fileExists(atPath: dest.appending(path: "Icon\r").path),
            "Stale top-level files must be removed"
        )
        XCTAssertFalse(
            fm.fileExists(atPath: dest.appending(path: "Contents/_CodeSignature").path),
            "Stale nested directories must be removed so re-signing starts clean"
        )
    }

    func testCreatesDestinationWhenAbsent() throws {
        let dest = scratch.appending(path: "Fresh.app")
        let staging = scratch.appending(path: ".staging.app")
        try makeBundle(at: staging, executable: "v1")

        try DirectoryInPlaceSync.sync(from: staging, to: dest, fileManager: fm)

        XCTAssertTrue(fm.fileExists(atPath: dest.appending(path: "Contents/MacOS/Poplet").path))
    }
}
