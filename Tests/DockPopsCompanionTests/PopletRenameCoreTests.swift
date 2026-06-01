import XCTest

// PopletRenameCore.swift is compiled directly into this test target (see
// project.yml) — pure / static + dependency-injected, so the rename/occupant
// algorithm is testable hostlessly. It was COPIED VERBATIM from DockPops
// Complete; these tests guard the copy against drift.

/// Records the bundle ids it was asked to terminate; reports which it pretends
/// were running. No process is touched.
final class MockPopletTerminator: PopletTerminating, @unchecked Sendable {
    let runningBundleIDs: Set<String>
    private(set) var terminatedBundleIDs: [String] = []

    init(runningBundleIDs: Set<String> = []) {
        self.runningBundleIDs = runningBundleIDs
    }

    func terminateRunningPoplet(bundleID: String, timeout: Duration) -> Bool {
        terminatedBundleIDs.append(bundleID)
        return runningBundleIDs.contains(bundleID)
    }
}

// MARK: - Pure decisions

final class PopletRenameDecisionTests: XCTestCase {
    func testRenameActionCreateWhenNoExistingBundle() {
        XCTAssertEqual(PopletRenameCore.renameAction(existingFilename: nil, desiredFilename: "Work.app"), .create)
    }
    func testRenameActionKeepWhenAlreadyCorrect() {
        XCTAssertEqual(PopletRenameCore.renameAction(existingFilename: "Work.app", desiredFilename: "Work.app"), .keep)
    }
    func testRenameActionRenameOnPopRename() {
        XCTAssertEqual(
            PopletRenameCore.renameAction(existingFilename: "Work.app", desiredFilename: "Personal.app"),
            .rename(from: "Work.app")
        )
    }
    func testShouldFlagRecoveryBannerOnlyForFailure() {
        XCTAssertTrue(PopletRenameCore.shouldFlagRecoveryBanner(for: .failed(NSError(domain: "x", code: 1))))
        XCTAssertFalse(PopletRenameCore.shouldFlagRecoveryBanner(for: .renamed))
        XCTAssertFalse(PopletRenameCore.shouldFlagRecoveryBanner(for: .deferred))
        XCTAssertFalse(PopletRenameCore.shouldFlagRecoveryBanner(for: .noBundle))
    }
    func testBundleIDPrefixIsUnified() {
        XCTAssertEqual(PopletRenameCore.popletBundleIDPrefix, "com.dockpops.poplet.")
    }
}

// MARK: - Disk fixtures shared by the rename tests

class PopletRenameDiskTestCase: XCTestCase {
    var tempDir: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appending(
            path: "PopletRenameCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        try? fm.removeItem(at: tempDir)
    }

    /// Build a `.app` with a marker file and, optionally, an embedded
    /// `DockPopsTargetPopID` (so the executor's occupant classifier can read it).
    @discardableResult
    func makeBundle(_ name: String, targetPopID: UUID? = nil) throws -> URL {
        let bundle = tempDir.appending(path: name, directoryHint: .isDirectory)
        let contents = bundle.appending(path: "Contents", directoryHint: .isDirectory)
        try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: contents.appending(path: "marker.txt"))
        if let targetPopID {
            let plist: [String: Any] = ["DockPopsTargetPopID": targetPopID.uuidString]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: contents.appending(path: "Info.plist"))
        }
        return bundle
    }

    func inode(of name: String) throws -> Int {
        let path = tempDir.appending(path: name, directoryHint: .isDirectory).path
        return try XCTUnwrap(try fm.attributesOfItem(atPath: path)[.systemFileNumber] as? Int)
    }

    func exists(_ name: String) -> Bool {
        fm.fileExists(atPath: tempDir.appending(path: name, directoryHint: .isDirectory).path)
    }
}

// MARK: - performBundleRename

final class PopletPerformRenameTests: PopletRenameDiskTestCase {
    func testRenamePreservesInode() throws {
        try makeBundle("Old.app")
        let before = try inode(of: "Old.app")
        let result = PopletRenameCore.performBundleRename(
            plan: .init(popID: UUID(), from: "Old.app", to: "New.app"),
            directory: tempDir, terminator: MockPopletTerminator(), fileManager: fm
        )
        guard case .renamed = result else { return XCTFail("expected .renamed, got \(result)") }
        XCTAssertTrue(exists("New.app"))
        XCTAssertFalse(exists("Old.app"))
        XCTAssertEqual(try inode(of: "New.app"), before, "inode survives → Dock pin follows")
    }

    func testTerminateInvokedWithUnifiedBundleID() throws {
        let popID = UUID()
        let expected = "com.dockpops.poplet.\(popID.uuidString.lowercased())"
        try makeBundle("Old.app")
        let terminator = MockPopletTerminator(runningBundleIDs: [expected])
        _ = PopletRenameCore.performBundleRename(
            plan: .init(popID: popID, from: "Old.app", to: "New.app"),
            directory: tempDir, terminator: terminator, fileManager: fm
        )
        XCTAssertEqual(terminator.terminatedBundleIDs, [expected])
    }

    func testRenameProceedsWhenNothingRunning() throws {
        try makeBundle("Old.app")
        let result = PopletRenameCore.performBundleRename(
            plan: .init(popID: UUID(), from: "Old.app", to: "New.app"),
            directory: tempDir, terminator: MockPopletTerminator(), fileManager: fm
        )
        guard case .renamed = result else { return XCTFail("expected .renamed, got \(result)") }
    }

    func testNoBundleWhenSourceMissing() {
        let result = PopletRenameCore.performBundleRename(
            plan: .init(popID: UUID(), from: "Ghost.app", to: "New.app"),
            directory: tempDir, terminator: MockPopletTerminator(), fileManager: fm
        )
        guard case .noBundle = result else { return XCTFail("expected .noBundle, got \(result)") }
    }

    func testDefersWhenDestinationOccupied() throws {
        try makeBundle("Old.app")
        try makeBundle("Taken.app")
        let result = PopletRenameCore.performBundleRename(
            plan: .init(popID: UUID(), from: "Old.app", to: "Taken.app"),
            directory: tempDir, terminator: MockPopletTerminator(), fileManager: fm
        )
        guard case .deferred = result else { return XCTFail("expected .deferred, got \(result)") }
        XCTAssertTrue(exists("Old.app"))
        XCTAssertTrue(exists("Taken.app"))
    }

    func testCaseOnlyRenameIsNotDeferred() throws {
        try makeBundle("foo.app")
        let before = try inode(of: "foo.app")
        let result = PopletRenameCore.performBundleRename(
            plan: .init(popID: UUID(), from: "foo.app", to: "Foo.app"),
            directory: tempDir, terminator: MockPopletTerminator(), fileManager: fm
        )
        guard case .renamed = result else { return XCTFail("expected .renamed, got \(result)") }
        let names = try fm.contentsOfDirectory(atPath: tempDir.path)
        XCTAssertTrue(names.contains("Foo.app"))
        XCTAssertFalse(names.contains { PopletRenameCore.isRenameTempFilename($0) }, "temp hop cleaned up")
        XCTAssertEqual(try inode(of: "Foo.app"), before, "case-only rename preserves the inode")
    }

    func testFailureLeavesSourceIntact() throws {
        try makeBundle("Old.app")
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempDir.path)
        let result = PopletRenameCore.performBundleRename(
            plan: .init(popID: UUID(), from: "Old.app", to: "New.app"),
            directory: tempDir, terminator: MockPopletTerminator(), fileManager: fm
        )
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
        guard case .failed = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertTrue(exists("Old.app"), "old bundle stays → pin valid")
        XCTAssertFalse(exists("New.app"))
        XCTAssertTrue(PopletRenameCore.shouldFlagRecoveryBanner(for: result))
    }
}

// MARK: - freshWriteFilename (occupant-safe new/recreate)

final class PopletFreshWriteFilenameTests: PopletRenameDiskTestCase {
    func testReturnsDesiredWhenFree() {
        let name = PopletRenameCore.freshWriteFilename(
            desired: "Work.app", popID: UUID(), directory: tempDir, fileManager: fm)
        XCTAssertEqual(name, "Work.app")
    }

    func testUniquifiesPastForeignOccupant() throws {
        try makeBundle("Work.app")   // foreign — no DockPopsTargetPopID
        let name = PopletRenameCore.freshWriteFilename(
            desired: "Work.app", popID: UUID(), directory: tempDir, fileManager: fm)
        XCTAssertEqual(name, "Work 2.app")
    }

    func testAdoptsOwnBundleAtDesired() throws {
        let popID = UUID()
        try makeBundle("Work.app", targetPopID: popID)   // our own bundle already there
        let name = PopletRenameCore.freshWriteFilename(
            desired: "Work.app", popID: popID, directory: tempDir, fileManager: fm)
        XCTAssertEqual(name, "Work.app", "adopt our own existing bundle rather than uniquify")
    }
}

// MARK: - Batch planner

final class PopletRenamePlannerTests: XCTestCase {
    private func assertPlanResolves(_ requests: [PopletRenameCore.PopletRenamePlan]) {
        let plan = PopletRenameCore.planRenames(requests)
        let realMoves = requests.filter { $0.from != $0.to }
        var occupied = Set(realMoves.map(\.from))
        var location: [UUID: String] = Dictionary(uniqueKeysWithValues: realMoves.map { ($0.popID, $0.from) })
        for move in plan {
            XCTAssertEqual(location[move.popID], move.from, "move source must be current location")
            XCTAssertFalse(occupied.contains(move.to), "move into occupied name: \(move.to)")
            occupied.remove(move.from)
            occupied.insert(move.to)
            location[move.popID] = move.to
        }
        for request in realMoves {
            XCTAssertEqual(location[request.popID], request.to, "Pop did not reach its desired name")
        }
    }

    func testDropsNoOpRenames() {
        XCTAssertTrue(PopletRenameCore.planRenames([.init(popID: UUID(), from: "Work.app", to: "Work.app")]).isEmpty)
    }
    func testSimpleRenameIsOneMove() {
        let id = UUID()
        XCTAssertEqual(
            PopletRenameCore.planRenames([.init(popID: id, from: "Old.app", to: "New.app")]),
            [.init(popID: id, from: "Old.app", to: "New.app")]
        )
    }
    func testTwoPopSwapViaTempHop() {
        let a = UUID(), b = UUID()
        let reqs: [PopletRenameCore.PopletRenamePlan] = [
            .init(popID: a, from: "Work.app", to: "Home.app"),
            .init(popID: b, from: "Home.app", to: "Work.app"),
        ]
        let plan = PopletRenameCore.planRenames(reqs)
        XCTAssertEqual(plan.count, 3, "swap = park one, move other, finish")
        XCTAssertTrue(plan.contains { PopletRenameCore.isRenameTempFilename($0.to) })
        assertPlanResolves(reqs)
    }
    func testThreePopCycle() {
        let a = UUID(), b = UUID(), c = UUID()
        assertPlanResolves([
            .init(popID: a, from: "A.app", to: "B.app"),
            .init(popID: b, from: "B.app", to: "C.app"),
            .init(popID: c, from: "C.app", to: "A.app"),
        ])
    }
    func testChainNeedsNoTemp() {
        let a = UUID(), b = UUID()
        let reqs: [PopletRenameCore.PopletRenamePlan] = [
            .init(popID: a, from: "A.app", to: "B.app"),
            .init(popID: b, from: "B.app", to: "C.app"),
        ]
        XCTAssertFalse(PopletRenameCore.planRenames(reqs).contains { PopletRenameCore.isRenameTempFilename($0.to) })
        assertPlanResolves(reqs)
    }
}

// MARK: - Batch executor (occupant matrix)

final class PopletRenameExecutorTests: PopletRenameDiskTestCase {
    private func run(_ requests: [PopletRenameCore.PopletRenamePlan]) -> [UUID: PopletRenameCore.BatchRenameOutcome] {
        let originalFrom = Dictionary(uniqueKeysWithValues: requests.map { ($0.popID, $0.from) })
        return PopletRenameCore.executeRenamePlan(
            PopletRenameCore.planRenames(requests),
            originalFrom: originalFrom, directory: tempDir,
            terminator: MockPopletTerminator(), fileManager: fm
        )
    }

    func testSwapLandsBothAndPreservesInodes() throws {
        let a = UUID(), b = UUID()
        try makeBundle("Work.app", targetPopID: a)
        try makeBundle("Home.app", targetPopID: b)
        let workInode = try inode(of: "Work.app")
        let homeInode = try inode(of: "Home.app")
        let outcomes = run([
            .init(popID: a, from: "Work.app", to: "Home.app"),
            .init(popID: b, from: "Home.app", to: "Work.app"),
        ])
        XCTAssertEqual(outcomes[a], .renamed("Home.app"))
        XCTAssertEqual(outcomes[b], .renamed("Work.app"))
        XCTAssertEqual(try inode(of: "Home.app"), workInode)
        XCTAssertEqual(try inode(of: "Work.app"), homeInode)
        XCTAssertFalse(try fm.contentsOfDirectory(atPath: tempDir.path).contains { PopletRenameCore.isRenameTempFilename($0) })
    }

    func testPlainRename() throws {
        let a = UUID()
        try makeBundle("Old.app", targetPopID: a)
        let before = try inode(of: "Old.app")
        XCTAssertEqual(run([.init(popID: a, from: "Old.app", to: "New.app")])[a], .renamed("New.app"))
        XCTAssertEqual(try inode(of: "New.app"), before)
    }

    func testDeadOrphanInTargetDefers() throws {
        // Target held by ANOTHER Pop's bundle (a sweepable dead orphan) → defer.
        let a = UUID()
        try makeBundle("Old.app", targetPopID: a)
        try makeBundle("Taken.app", targetPopID: UUID())   // some other (dead) Pop
        XCTAssertEqual(run([.init(popID: a, from: "Old.app", to: "Taken.app")])[a], .deferred("Old.app"))
        XCTAssertTrue(exists("Old.app"), "source kept (pin valid)")
    }

    func testForeignOccupantUniquifies() throws {
        // Target held by a FOREIGN `.app` (no DockPopsTargetPopID) → uniquify
        // past it rather than defer forever (the sweep preserves foreign apps).
        let a = UUID()
        try makeBundle("Old.app", targetPopID: a)
        try makeBundle("Taken.app")   // foreign occupant
        XCTAssertEqual(run([.init(popID: a, from: "Old.app", to: "Taken.app")])[a], .renamed("Taken 2.app"))
        XCTAssertTrue(exists("Taken.app"), "foreign occupant untouched")
        XCTAssertTrue(exists("Taken 2.app"))
    }

    func testSelfDuplicateAtTargetIsRemovedThenRenamed() throws {
        // Target held by a redundant copy of OUR OWN Pop (e.g. registry
        // rollback) → remove the dup and finish the rename.
        let a = UUID()
        try makeBundle("Old.app", targetPopID: a)
        try makeBundle("Taken.app", targetPopID: a)   // self-duplicate
        XCTAssertEqual(run([.init(popID: a, from: "Old.app", to: "Taken.app")])[a], .renamed("Taken.app"))
        XCTAssertFalse(exists("Old.app"))
        XCTAssertTrue(exists("Taken.app"))
    }
}
