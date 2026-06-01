import XCTest

// PopletRegistry.swift is compiled directly into this test target (see
// project.yml) so the pure logic is testable without launching the app host
// (which pulls in Sparkle + the full SwiftUI scene).

final class PopletRegistryTests: XCTestCase {

    private func sanitize(_ raw: String) -> String {
        // Mirror of PopletSyncService.sanitizedPopletName for resolution tests.
        let replaced = raw.replacingOccurrences(
            of: #"[/:\\]+"#, with: "-", options: .regularExpression
        )
        let compact = replaced.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        )
        let trimmed = compact.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Pop" : trimmed
    }

    // MARK: - Migration

    func testDecodesModernUUIDKeyedShape() throws {
        let json = """
        {"\(UUID().uuidString)":{"displayName":"Work","filename":"Work.app"}}
        """
        let map = try PopletRegistry.decode(Data(json.utf8))
        XCTAssertEqual(map.count, 1)
        XCTAssertEqual(map.values.first, PopletRegistryEntry(filename: "Work.app", displayName: "Work"))
    }

    func testMigratesLegacyNameToUUIDShape() throws {
        let uuid = UUID()
        let legacy = "{\"Work\":\"\(uuid.uuidString)\"}"
        let map = try PopletRegistry.decode(Data(legacy.utf8))
        XCTAssertEqual(
            map[uuid.uuidString],
            PopletRegistryEntry(filename: "Work.app", displayName: "Work"),
            "Legacy [name→uuid] must migrate to a <name>.app filename"
        )
    }

    func testDecodesEmptyObject() throws {
        let map = try PopletRegistry.decode(Data("{}".utf8))
        XCTAssertTrue(map.isEmpty)
    }

    // MARK: - Encoding idempotency

    func testEncodeIsByteStableAndSorted() throws {
        let a = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let b = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let map: PopletRegistry.Map = [
            b.uuidString: PopletRegistryEntry(filename: "B.app", displayName: "B"),
            a.uuidString: PopletRegistryEntry(filename: "A.app", displayName: "A"),
        ]
        let first = try PopletRegistry.encode(map)
        let second = try PopletRegistry.encode(map)
        XCTAssertEqual(first, second, "Encoding the same map must produce identical bytes (watcher-loop guard)")
        // Sorted keys: the A-uuid entry sorts before the B-uuid entry.
        let string = String(decoding: first, as: UTF8.self)
        XCTAssertLessThan(
            string.range(of: a.uuidString)!.lowerBound,
            string.range(of: b.uuidString)!.lowerBound
        )
    }

    // MARK: - Name resolution (name-tracking, first occurrence bare)

    func testResolvedNameSanitizesIllegalCharacters() {
        let id = UUID()
        let names = PopletRegistry.resolvedDisplayNames(for: [(id, "TV/Movies")], sanitize: sanitize)
        XCTAssertEqual(names[id], "TV-Movies")
    }

    func testResolvedNameFallsBackForEmptyName() {
        let id = UUID()
        let names = PopletRegistry.resolvedDisplayNames(for: [(id, "   ")], sanitize: sanitize)
        XCTAssertEqual(names[id], "Pop")
    }

    func testFirstOccurrenceKeepsBareNameLaterDuplicatesGetSuffix() {
        let a = UUID(), b = UUID(), c = UUID()
        let names = PopletRegistry.resolvedDisplayNames(
            for: [(a, "Work"), (b, "Work"), (c, "Work")], sanitize: sanitize
        )
        // Stable order → primary keeps the bare name (what the MAS reader wants).
        XCTAssertEqual(names[a], "Work")
        XCTAssertEqual(names[b], "Work 2")
        XCTAssertEqual(names[c], "Work 3")
    }

    func testResolvedNamesAreStableAcrossSyncs() {
        let a = UUID(), b = UUID()
        let first = PopletRegistry.resolvedDisplayNames(for: [(a, "Games"), (b, "Games")], sanitize: sanitize)
        let second = PopletRegistry.resolvedDisplayNames(for: [(a, "Games"), (b, "Games")], sanitize: sanitize)
        XCTAssertEqual(first[a], "Games")
        XCTAssertEqual(first[b], "Games 2")
        XCTAssertEqual(first, second, "stable order → suffix does not ping-pong across syncs")
    }

    // MARK: - Orphan sweep selection

    func testOrphanSweepRemovesOnlyMissingUUIDs() {
        let live = UUID()
        let orphan = UUID()
        let onDisk: [(filename: String, targetPopID: UUID?)] = [
            ("Live.app", live),
            ("Old.app", orphan),
        ]
        let removed = PopletRegistry.orphanFilenames(onDisk: onDisk, currentPopIDs: [live])
        XCTAssertEqual(removed, ["Old.app"])
    }

    func testOrphanSweepKeepsLivePopRegardlessOfFilename() {
        let live = UUID()
        // Frozen filename diverged from the current name — still kept by UUID.
        let onDisk: [(filename: String, targetPopID: UUID?)] = [("StaleName.app", live)]
        let removed = PopletRegistry.orphanFilenames(onDisk: onDisk, currentPopIDs: [live])
        XCTAssertTrue(removed.isEmpty)
    }

    func testOrphanSweepIgnoresKeylessAndHiddenAndTempBundles() {
        let onDisk: [(filename: String, targetPopID: UUID?)] = [
            ("Foreign.app", nil),                                   // no embedded UUID
            (".Hidden.app", UUID()),                                // hidden / dot-prefixed
            (".Work.staging.\(UUID().uuidString).app", UUID()),     // temp staging bundle
            ("NotAnApp.txt", UUID()),                               // non-bundle
        ]
        let removed = PopletRegistry.orphanFilenames(onDisk: onDisk, currentPopIDs: [])
        XCTAssertTrue(removed.isEmpty, "Foreign/keyless, hidden, temp, and non-.app entries are never swept")
    }
}
