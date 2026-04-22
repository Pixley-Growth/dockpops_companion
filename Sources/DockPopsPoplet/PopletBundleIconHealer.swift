import Darwin
import Foundation
import os

/// Method C1 — on poplet launch, rebuilds the bundle's `Contents/Resources/AppIcon.icns`
/// when the mirrored live icon PNG is newer, then re-signs the bundle ad-hoc
/// and nudges Launch Services so Finder and the Dock-at-rest tile reflect the
/// current icon.
///
/// Intentionally runs off the main actor so launch isn't blocked by iconutil /
/// codesign. Uses `CGImage` + `ImageIO` (Sendable-friendly) rather than NSImage
/// so Swift 6 concurrency is happy.
struct PopletBundleIconHealer: Sendable {
    private static let logger = Logger(
        subsystem: "com.dockpops.companion.poplet",
        category: "IconHealer"
    )
    private static let iconName = "AppIcon"
    private static let iconRecipeVersion = 3
    private static let iconRecipeVersionInfoKey = "DockPopsIconRecipeVersion"
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
        self.sourcePNG = PopletSharedPaths.mirroredPopIconURL(for: popID)
        if let sourcePNG {
            PopletSharedPaths.assertUsesMirroredLiveIconFile(sourcePNG)
        }
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

        guard FileManager.default.fileExists(atPath: sourcePNG.path) else { return }
        guard try sourceIsNewer(source: sourcePNG, target: targetICNS) else { return }

        try regenerateICNS(from: sourcePNG, to: targetICNS)
        try signBundle(at: bundleURL)
        registerWithLaunchServices(bundleURL: bundleURL)

        Self.logger.info(
            "icon healed for \(bundleURL.lastPathComponent, privacy: .public)"
        )
    }

    private func sourceIsNewer(source: URL, target: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: target.path) else { return true }
        if storedIconRecipeVersion() != Self.iconRecipeVersion {
            return true
        }
        let sourceDate = try source.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        let targetDate = try target.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        guard let sourceDate, let targetDate else { return true }
        return sourceDate > targetDate
    }

    private func storedIconRecipeVersion() -> Int? {
        guard
            let infoDictionary = Bundle(url: bundleURL)?.infoDictionary,
            let recipeVersion = infoDictionary[Self.iconRecipeVersionInfoKey] as? Int
        else {
            return nil
        }
        return recipeVersion
    }

    private func regenerateICNS(from pngURL: URL, to icnsURL: URL) throws {
        guard let rawImage = PopletIconRendering.loadImage(at: pngURL) else {
            throw PopletIconError.imageLoadFailed(pngURL)
        }
        let normalized = PopletIconRendering.normalizedCanvas(from: rawImage) ?? rawImage

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
                from: normalized,
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
