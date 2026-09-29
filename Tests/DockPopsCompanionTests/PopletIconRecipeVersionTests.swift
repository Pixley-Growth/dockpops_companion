import XCTest
import PopletKit

/// Pins the generator's `DockPopsIconRecipeVersion` stamp (PopletKit) to the
/// value the Poplet healer expects (`PopletIconRecipe.version`). If they drift,
/// each side treats the other's bundle as stale and every Poplet is rebuilt in
/// a loop. Generates a real bundle rather than hardcoding PopletKit's number,
/// so a PopletKit bump that changes the stamp fails here.
final class PopletIconRecipeVersionTests: XCTestCase {
    private struct NoopTerminator: PopletTerminating {
        func terminateRunningPoplet(bundleID: String, timeout: Duration) -> Bool { true }
    }

    private var tempDir: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tempDir = fm.temporaryDirectory.appending(
            path: "PopletIconRecipeVersionTests-\(UUID().uuidString)", directoryHint: .isDirectory
        )
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tempDir)
    }

    func testGeneratorStampMatchesHealerRecipeVersion() throws {
        let env = PopletEnvironment(
            popletsDirectory: tempDir.appending(path: "Applications/DockPops", directoryHint: .isDirectory),
            registryURL: tempDir.appending(path: "poplet-registry.json"),
            popletExecutableSource: URL(fileURLWithPath: "/usr/bin/true")
        )
        let id = UUID()
        let stats = PopletKit.sync(
            specs: [PopletSpec(id: id, displayName: "Recipe")],
            in: env,
            terminator: NoopTerminator(),
            fileManager: fm
        )
        XCTAssertEqual(stats.created, 1)

        let bundleURL = try XCTUnwrap(PopletKit.currentBundleURL(for: id, in: env, fileManager: fm))
        let infoURL = bundleURL.appending(path: "Contents/Info.plist")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: try Data(contentsOf: infoURL), options: [], format: nil
        ) as? [String: Any])
        let stamp = try XCTUnwrap(plist["DockPopsIconRecipeVersion"] as? Int)

        XCTAssertEqual(
            stamp, PopletIconRecipe.version,
            "PopletKit stamps \(stamp) but the healer expects \(PopletIconRecipe.version) — update PopletIconRecipe.version"
        )
    }
}
