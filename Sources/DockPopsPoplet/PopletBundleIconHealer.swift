import AppKit
import Darwin
import Foundation
import os

/// Method C1 — on poplet launch, rebuilds the bundle's `Contents/Resources/AppIcon.icns`
/// when the mirrored live icon PNG is newer, then re-signs the bundle ad-hoc
/// and nudges Launch Services so Finder and the Dock-at-rest tile reflect the
/// current icon.
///
/// Intentionally runs off the main actor so launch isn't blocked by iconutil /
/// codesign. ICNS regeneration uses `CGImage` + `ImageIO`; the Finder custom
/// icon handoff hops to the main actor because it uses NSWorkspace.
struct PopletBundleIconHealer: Sendable {
    private static let logger = Logger(
        subsystem: "com.dockpops.companion.poplet",
        category: "IconHealer"
    )
    private static let iconName = "AppIcon"
    private static let iconRecipeVersion = 13
    private static let iconRecipeVersionInfoKey = "DockPopsIconRecipeVersion"
    private static let bundleIconNameInfoKey = "CFBundleIconName"
    private static let iconVariants: [(name: String, pixelSize: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    private static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Support/lsregister"

    let popID: UUID
    let bundleURL: URL
    let sourcePNG: URL?

    init(popID: UUID, bundleURL: URL) {
        self.popID = popID
        self.bundleURL = bundleURL
        // Canonical 1024² master written by DockPops Main. NOT the Companion
        // mirror (stale when Companion isn't running) and NOT .live.png (256²
        // runtime variant — too small for iconutil's 1024² slot).
        self.sourcePNG = Self.canonicalPopIconURL(for: popID)
    }

    private static func canonicalPopIconURL(for popID: UUID) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Group Containers/group.com.dockpops.shared", directoryHint: .isDirectory)
            .appending(path: "PopIcons", directoryHint: .isDirectory)
            .appending(path: "\(popID.uuidString).png")
    }

    func healIfStale() async {
        do {
            try await withBundleLock {
                try await performHealIfStale()
            }
        } catch {
            Self.logger.error(
                "icon heal failed for \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func performHealIfStale() async throws {
        guard let sourcePNG else { return }
        let targetICNS = bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
            .appending(path: "\(Self.iconName).icns")

        guard FileManager.default.fileExists(atPath: sourcePNG.path) else {
            Self.logger.info("canonical missing for \(self.bundleURL.lastPathComponent, privacy: .public)")
            return
        }
        guard try bundleNeedsHeal(source: sourcePNG, target: targetICNS) else { return }

        try await clearFinderCustomIconIfPresent()
        try regenerateICNS(from: sourcePNG, to: targetICNS)
        try regenerateOrRemoveAssetsCar(from: sourcePNG)
        try stampRecipeVersionInInfoPlist()
        try signBundle(at: bundleURL)
        // ════════════════════════════════════════════════════════════════
        // SACRED ZONE #28 — REVISED 2026-05-21
        // ════════════════════════════════════════════════════════════════
        //
        // Apply the Finder custom icon AFTER signing. This is the same
        // "Path B" ordering Companion uses at generation time
        // (PopletSyncService.applyFinderCustomIconIfPossible). The
        // Finder custom icon is the load-bearing escape hatch from
        // macOS' static app-icon rendering path that adds the Tahoe
        // plate around runtime-generated bundles — see
        // docs/tahoe-icon-plate-handoff.md. Without this reapply, the
        // closed Dock tile and Finder view show the plated icon even
        // when the underlying AppIcon.icns / Assets.car / Info.plist
        // are all correct.
        //
        // PRIOR ART (`7ca31d0`, this comment's previous content): the
        // earlier SACRED #28 forbade this call because user-reported
        // "Dock cycles through a generic folder icon" on every click.
        // That diagnosis is conditional on observer timing — the live
        // icon controller now starts synchronously in
        // applicationDidFinishLaunching, well before this detached heal
        // task could invalidate the bundle signature, and applicationIcon-
        // Image overrides the static-bundle render path for the running
        // tile. So the flash should not be user-visible. If a flash IS
        // observed in practice, the spec
        // docs/specs/fix-healer-to-check-canonical-on-click-every-click.md
        // requires a STOP-and-redesign — NOT a silent fallback to
        // strip-without-reapply, which re-introduces the Tahoe plate.
        //
        // The signature is intentionally invalidated by setIcon (it
        // writes Icon\r + FinderInfo xattr). codesign --verify --strict
        // will fail post-heal; macOS' normal LaunchServices path
        // accepts it. This is the same trade-off Companion accepts at
        // generation time.
        // ════════════════════════════════════════════════════════════════
        await applyFinderCustomIconIfPossible(from: sourcePNG)
        registerWithLaunchServices(bundleURL: bundleURL)

        Self.logger.info(
            "icon healed for \(bundleURL.lastPathComponent, privacy: .public)"
        )
    }

    /// Returns true when the bundle's on-disk icon state diverges from the
    /// current source-of-truth or has been damaged.
    ///
    /// Five triggers, any of which forces a heal:
    /// 1. Stored `DockPopsIconRecipeVersion` doesn't match this healer's version
    /// 2. `Contents/Resources/AppIcon.icns` missing
    /// 3. Source (canonical .png) is newer than `AppIcon.icns`
    /// 4. `Contents/Icon\r` missing (Finder custom icon resource damaged/stripped)
    /// 5. `com.apple.FinderInfo` xattr missing on bundle (Tahoe-plate workaround stripped)
    private func bundleNeedsHeal(source: URL, target: URL) throws -> Bool {
        // Trigger 1
        if storedIconRecipeVersion() != Self.iconRecipeVersion {
            return true
        }
        // Trigger 2
        guard FileManager.default.fileExists(atPath: target.path) else {
            return true
        }
        // Trigger 3
        let sourceDate = try source.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        let targetDate = try target.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        if let sourceDate, let targetDate, sourceDate > targetDate {
            return true
        }
        // Trigger 4
        let iconResourceURL = bundleURL.appending(path: "Icon\r")
        if !FileManager.default.fileExists(atPath: iconResourceURL.path) {
            return true
        }
        // Trigger 5
        if !hasFinderCustomIconAttribute(bundleURL: bundleURL) {
            return true
        }
        return false
    }

    private func hasFinderCustomIconAttribute(bundleURL: URL) -> Bool {
        bundleURL.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            let size = Darwin.getxattr(path, "com.apple.FinderInfo", nil, 0, 0, 0)
            return size > 0
        }
    }

    private func storedIconRecipeVersion() -> Int? {
        // Read Info.plist directly from disk. `Bundle(url:)?.infoDictionary`
        // routes through the global Bundle cache, which is loaded once at
        // process startup and never refreshed. Since `stampRecipeVersionInInfoPlist`
        // writes to disk during a heal, the Bundle-cache reader would keep
        // returning the pre-startup value forever — making the version trigger
        // re-fire on every subsequent click within the same poplet session.
        let infoPlistURL = bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Info.plist")
        guard
            let data = try? Data(contentsOf: infoPlistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let recipeVersion = plist[Self.iconRecipeVersionInfoKey] as? Int
        else {
            return nil
        }
        return recipeVersion
    }

    private func regenerateICNS(from pngURL: URL, to icnsURL: URL) throws {
        guard let rawImage = PopletIconRendering.loadImage(at: pngURL) else {
            throw PopletIconError.imageLoadFailed(pngURL)
        }
        // SACRED: bake from the NORMALIZED/inset canvas, not raw full-bleed.
        // Companion's PopletSyncService:341 calls `normalizedPopletAppIcon()`
        // before baking; if the healer bakes raw, the closed Dock tile renders
        // ~15% oversized vs sibling icons (regression 48f9cad). The
        // `PopletIconRendering.contentScale` / `cornerRadiusRatio` constants
        // mirror that path.
        guard let normalizedImage = PopletIconRendering.normalizedCanvas(from: rawImage) else {
            throw PopletIconError.imageLoadFailed(pngURL)
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "DockPopsPoplet-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let iconsetURL = tempRoot.appending(
            path: "\(Self.iconName).iconset",
            directoryHint: .isDirectory
        )
        let builtICNSURL = tempRoot.appending(path: "\(Self.iconName).icns")

        try FileManager.default.createDirectory(
            at: iconsetURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for variant in Self.iconVariants {
            guard let data = PopletIconRendering.resizedPNGData(
                from: normalizedImage,
                pixelSize: variant.pixelSize
            ) else {
                throw PopletIconError.iconsetVariantFailed(variant.name)
            }
            try data.write(
                to: iconsetURL.appending(path: variant.name),
                options: .atomic
            )
        }

        try runProcess(
            executable: "/usr/bin/iconutil",
            arguments: ["-c", "icns", iconsetURL.path, "-o", builtICNSURL.path],
            failureMessage: "iconutil failed"
        )

        let icnsData = try Data(contentsOf: builtICNSURL)
        try icnsData.write(to: icnsURL, options: .atomic)
    }

    /// Handles `Assets.car` parity with Companion's bake. The bundle's
    /// `CFBundleIconName` Info.plist key points LaunchServices at the
    /// asset-catalog icon when present; we MUST either refresh that catalog
    /// or remove the pointer, otherwise a stale `Assets.car` keeps painting
    /// the old composite on closed tiles.
    ///
    /// `actool` ships with Xcode, not macOS — typical end-user machines do
    /// not have it. In that case the catalog is removed and `CFBundleIconName`
    /// is cleared so LaunchServices falls back to the fresh `AppIcon.icns`.
    private func regenerateOrRemoveAssetsCar(from pngURL: URL) throws {
        let resourcesURL = bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Resources", directoryHint: .isDirectory)
        let assetCatalogURL = resourcesURL.appending(path: "Assets.car")

        if let actoolURL = Self.locateActool() {
            // SACRED: same normalized canvas as regenerateICNS — both must
            // bake from the inset/rounded image, not raw full-bleed.
            guard let rawImage = PopletIconRendering.loadImage(at: pngURL),
                  let normalizedImage = PopletIconRendering.normalizedCanvas(from: rawImage),
                  let normalizedPNG = PopletIconRendering.pngData(from: normalizedImage)
            else {
                throw PopletIconError.imageLoadFailed(pngURL)
            }
            let newData = try compileAssetsCar(
                actoolURL: actoolURL,
                normalizedPNG: normalizedPNG
            )
            try newData.write(to: assetCatalogURL, options: .atomic)
            // CFBundleIconName key stays in Info.plist; Companion already set
            // it at generation time.
        } else {
            // Clear the Info.plist pointer FIRST, then delete the file. If the
            // file removal fails for any reason, the bundle stays consistent
            // (no CFBundleIconName, falls back to AppIcon.icns regardless of
            // whether a stale Assets.car is still on disk).
            try mutateInfoPlist { plist in
                plist.removeValue(forKey: Self.bundleIconNameInfoKey)
            }
            if FileManager.default.fileExists(atPath: assetCatalogURL.path) {
                try FileManager.default.removeItem(at: assetCatalogURL)
            }
        }
    }

    private static func locateActool() -> URL? {
        // Avoid triggering Command Line Tools installer; only return actool
        // if it actually exists at the expected path.
        let candidates = [
            "/Applications/Xcode.app/Contents/Developer/usr/bin/actool",
            "/Library/Developer/CommandLineTools/usr/bin/actool",
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func compileAssetsCar(actoolURL: URL, normalizedPNG: Data) throws -> Data {
        let tempRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "DockPopsPopletAssets-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        let xcassetsURL = tempRoot.appending(
            path: "Sources.xcassets",
            directoryHint: .isDirectory
        )
        let appIconURL = xcassetsURL.appending(
            path: "\(Self.iconName).appiconset",
            directoryHint: .isDirectory
        )
        let outputDirURL = tempRoot.appending(
            path: "out",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: appIconURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDirURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // Single Universal slot using the full normalized canvas. actool
        // downsamples to the smaller representations.
        let imageFilename = "\(Self.iconName).png"
        try normalizedPNG.write(to: appIconURL.appending(path: imageFilename), options: .atomic)

        let contentsJSON: [String: Any] = [
            "info": ["author": "xcode", "version": 1],
            "images": [
                [
                    "filename": imageFilename,
                    "idiom": "mac",
                    "platform": "macos",
                    "size": "1024x1024",
                ]
            ],
        ]
        let contentsData = try JSONSerialization.data(
            withJSONObject: contentsJSON,
            options: [.prettyPrinted]
        )
        try contentsData.write(to: appIconURL.appending(path: "Contents.json"), options: .atomic)

        let xcassetsContents: [String: Any] = ["info": ["author": "xcode", "version": 1]]
        let xcassetsContentsData = try JSONSerialization.data(
            withJSONObject: xcassetsContents,
            options: [.prettyPrinted]
        )
        try xcassetsContentsData.write(
            to: xcassetsURL.appending(path: "Contents.json"),
            options: .atomic
        )

        try runProcess(
            executable: actoolURL.path,
            arguments: [
                "--compile", outputDirURL.path,
                "--platform", "macosx",
                "--minimum-deployment-target", "14.0",
                "--app-icon", Self.iconName,
                "--output-partial-info-plist", tempRoot.appending(path: "partial.plist").path,
                xcassetsURL.path,
            ],
            failureMessage: "actool failed"
        )

        return try Data(contentsOf: outputDirURL.appending(path: "Assets.car"))
    }

    /// Writes `DockPopsIconRecipeVersion = Self.iconRecipeVersion` to the
    /// bundle's Info.plist. MUST run before `signBundle` so the signature
    /// covers the updated version. Without this, future version bumps cause
    /// the recipe-mismatch trigger to fire on every click forever.
    private func stampRecipeVersionInInfoPlist() throws {
        try mutateInfoPlist { plist in
            plist[Self.iconRecipeVersionInfoKey] = Self.iconRecipeVersion
        }
    }

    private func mutateInfoPlist(_ mutate: (inout [String: Any]) -> Void) throws {
        let infoPlistURL = bundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Info.plist")
        let data = try Data(contentsOf: infoPlistURL)
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw PopletIconError.imageLoadFailed(infoPlistURL)
        }
        mutate(&plist)
        let outData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        )
        try outData.write(to: infoPlistURL, options: .atomic)
    }

    @MainActor
    private func clearFinderCustomIconIfPresent() throws {
        _ = NSWorkspace.shared.setIcon(nil, forFile: bundleURL.path, options: [])

        let iconFileURL = bundleURL.appending(path: "Icon\r")
        if FileManager.default.fileExists(atPath: iconFileURL.path) {
            try? FileManager.default.removeItem(at: iconFileURL)
        }

        let removalError: Int32 = bundleURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return EINVAL }
            if Darwin.removexattr(path, "com.apple.FinderInfo", 0) == 0 {
                return 0
            }
            return errno
        }

        if removalError != 0 && removalError != ENOATTR {
            throw POSIXError(POSIXErrorCode(rawValue: removalError) ?? .EIO)
        }
    }

    @MainActor
    private func applyFinderCustomIconIfPossible(from pngURL: URL) {
        let image: NSImage
        if
            let rawImage = PopletIconRendering.loadImage(at: pngURL),
            let normalized = PopletIconRendering.normalizedCanvas(from: rawImage)
        {
            image = NSImage(
                cgImage: normalized,
                size: NSSize(width: CGFloat(normalized.width), height: CGFloat(normalized.height))
            )
        } else if let loadedImage = NSImage(contentsOf: pngURL) {
            image = loadedImage
        } else {
            Self.logger.error(
                "custom icon image load failed for \(bundleURL.lastPathComponent, privacy: .public): \(pngURL.path, privacy: .public)"
            )
            return
        }

        guard NSWorkspace.shared.setIcon(image, forFile: bundleURL.path, options: []) else {
            Self.logger.error(
                "custom icon apply failed for \(bundleURL.lastPathComponent, privacy: .public)"
            )
            return
        }
        NSWorkspace.shared.noteFileSystemChanged(bundleURL.path)
    }

    private func signBundle(at url: URL) throws {
        try runProcess(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", url.path],
            failureMessage: "codesign failed"
        )
    }

    /// Best-effort — if `lsregister` fails (missing on some minimal macOS
    /// installs, SIP weirdness) the rewritten ICNS still wins eventually once
    /// Dock/Finder caches flush on their own. Don't abort the heal.
    private func registerWithLaunchServices(bundleURL: URL) {
        do {
            try runProcess(
                executable: Self.lsregisterPath,
                arguments: ["-f", bundleURL.path],
                failureMessage: "lsregister failed"
            )
        } catch {
            Self.logger.error(
                "lsregister nudge failed for \(bundleURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func withBundleLock<Result>(
        _ body: () async throws -> Result
    ) async throws -> Result {
        let lockHandle = try BundleLockHandle(lockURL: bundleLockURL())
        defer {
            lockHandle.unlock()
        }
        return try await body()
    }

    private func bundleLockURL() -> URL {
        bundleURL.deletingLastPathComponent().appending(path: ".\(bundleURL.lastPathComponent).lock")
    }

    @discardableResult
    private func runProcess(
        executable: String,
        arguments: [String],
        failureMessage: String
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        let collector = ProcessOutputCollector()

        handle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            collector.append(chunk)
        }
        defer {
            handle.readabilityHandler = nil
        }

        try process.run()
        process.waitUntilExit()
        let remaining = handle.readDataToEndOfFile()
        if !remaining.isEmpty {
            collector.append(remaining)
        }

        let output = collector.stringValue

        guard process.terminationStatus == 0 else {
            throw PopletIconError.processFailed(message: failureMessage, output: output)
        }
        return output
    }
}

private final class ProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private final class BundleLockHandle {
    private let fileDescriptor: Int32
    private var isUnlocked = false

    init(lockURL: URL) throws {
        let fileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fileDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        guard flock(fileDescriptor, LOCK_EX) == 0 else {
            let lockError = errno
            close(fileDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }

        self.fileDescriptor = fileDescriptor
    }

    func unlock() {
        guard !isUnlocked else { return }
        isUnlocked = true
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    deinit {
        unlock()
    }
}

private enum PopletIconError: Error, LocalizedError {
    case imageLoadFailed(URL)
    case iconsetVariantFailed(String)
    case processFailed(message: String, output: String)

    var errorDescription: String? {
        switch self {
        case let .imageLoadFailed(url):
            return "Could not load pop composite PNG at \(url.path)"
        case let .iconsetVariantFailed(name):
            return "Could not render iconset variant \(name)"
        case let .processFailed(message, output):
            return output.isEmpty ? message : "\(message): \(output)"
        }
    }
}
