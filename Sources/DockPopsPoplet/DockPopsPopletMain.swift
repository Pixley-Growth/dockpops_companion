import AppKit
import Foundation

@MainActor
@main
enum DockPopsPopletMain {
    private static let delegate = DockPopsPopletDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
private final class DockPopsPopletDelegate: NSObject, NSApplicationDelegate {
    private let rawPopID = (Bundle.main.infoDictionary?["DockPopsTargetPopID"] as? String) ?? ""
    private lazy var iconController = PopletIconController(
        rawPopID: rawPopID,
        bundleURL: Bundle.main.bundleURL
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard UUID(uuidString: rawPopID) != nil else {
            NSApp.terminate(nil)
            return
        }

        installMenu()
        iconController.start()
        openPop()
    }

    func applicationWillTerminate(_ notification: Notification) {
        iconController.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openPop()
        return false
    }

    @objc
    private func openPopFromMenu(_ sender: Any?) {
        openPop()
    }

    @objc
    private func quitFromMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    private func openPop() {
        let mouse = NSEvent.mouseLocation
        var components = URLComponents()
        components.scheme = "dockpops"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "pop", value: rawPopID),
            URLQueryItem(name: "x", value: String(Double(mouse.x))),
            URLQueryItem(name: "y", value: String(Double(mouse.y))),
            URLQueryItem(name: "locked", value: "1"),
        ]

        guard let url = components.url else { return }
        _ = NSWorkspace.shared.open(url)
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "DockPops Pop"

        let openTitle = "Open \(appName)"
        let openItem = NSMenuItem(
            title: openTitle,
            action: #selector(openPopFromMenu(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        appMenu.addItem(openItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(quitFromMenu(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)

        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}

@MainActor
private final class PopletIconController {
    private let fileManager = FileManager.default
    private let bundleURL: URL
    private let popID: UUID?
    private var refreshTimer: Timer?
    private var lastAppliedSignature: IconSignature?

    init(rawPopID: String, bundleURL: URL) {
        self.bundleURL = bundleURL
        self.popID = UUID(uuidString: rawPopID)
    }

    func start() {
        refreshIconIfNeeded(force: true)

        let timer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshIconIfNeeded()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refreshIconIfNeeded(force: Bool = false) {
        guard let signature = currentIconSignature() else { return }
        guard force || signature != lastAppliedSignature else { return }

        switch signature {
        case .popComposite(let iconURL, _, _):
            guard
                let image = NSImage(contentsOf: iconURL),
                let normalized = image.normalizedPopletAppIcon()
            else {
                return
            }
            applyIcon(normalized)
        case .dockPopsFallback:
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: PopletEnvironment.dockPopsBundleIdentifier) else {
                return
            }
            let image = NSWorkspace.shared.icon(forFile: appURL.path)
            applyIcon(image)
        case .generic:
            NSWorkspace.shared.setIcon(nil, forFile: bundleURL.path, options: [])
            if let current = NSWorkspace.shared.icon(forFile: bundleURL.path) as NSImage? {
                NSApp.applicationIconImage = current
            }
        }

        lastAppliedSignature = signature
    }

    private func applyIcon(_ image: NSImage) {
        NSWorkspace.shared.setIcon(image, forFile: bundleURL.path, options: [])
        NSApp.applicationIconImage = image
    }

    private func currentIconSignature() -> IconSignature? {
        if
            let popID,
            let popIconURL = popIconURL(for: popID),
            let fileSignature = fileSignature(for: popIconURL)
        {
            return .popComposite(
                iconURL: popIconURL,
                modificationDate: fileSignature.modificationDate,
                fileSize: fileSignature.fileSize
            )
        }

        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: PopletEnvironment.dockPopsBundleIdentifier) != nil {
            return .dockPopsFallback
        }

        return .generic
    }

    private func popIconURL(for popID: UUID) -> URL? {
        let iconURL = PopletEnvironment.sharedPopIconsDirectoryURL
            .appending(path: "\(popID.uuidString).png")
        return fileManager.fileExists(atPath: iconURL.path) ? iconURL : nil
    }

    private func fileSignature(for url: URL) -> FileSignature? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }

        return FileSignature(
            modificationDate: values.contentModificationDate,
            fileSize: values.fileSize
        )
    }
}

private enum PopletEnvironment {
    static let dockPopsBundleIdentifier = "com.dockpops.app"
    static let sharedPopIconsDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Group Containers", directoryHint: .isDirectory)
        .appending(path: "group.com.dockpops.shared", directoryHint: .isDirectory)
        .appending(path: "PopIcons", directoryHint: .isDirectory)
}

private struct FileSignature: Equatable {
    let modificationDate: Date?
    let fileSize: Int?
}

private enum IconSignature: Equatable {
    case popComposite(iconURL: URL, modificationDate: Date?, fileSize: Int?)
    case dockPopsFallback
    case generic
}

private extension NSImage {
    func normalizedPopletAppIcon(
        canvasSize: CGFloat = 1024,
        contentScale: CGFloat = 0.86
    ) -> NSImage? {
        var proposedRect = CGRect(origin: .zero, size: size)
        let resolvedCGImage = cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
            ?? representations.compactMap { ($0 as? NSBitmapImageRep)?.cgImage }.first

        guard let resolvedCGImage else { return nil }

        let targetRect = CGRect(
            x: (canvasSize - (canvasSize * contentScale)) / 2,
            y: (canvasSize - (canvasSize * contentScale)) / 2,
            width: canvasSize * contentScale,
            height: canvasSize * contentScale
        )

        guard
            let context = CGContext(
                data: nil,
                width: Int(canvasSize),
                height: Int(canvasSize),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: canvasSize, height: canvasSize))
        context.draw(resolvedCGImage, in: targetRect)

        guard let outputImage = context.makeImage() else { return nil }
        return NSImage(cgImage: outputImage, size: NSSize(width: canvasSize, height: canvasSize))
    }
}
