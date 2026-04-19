import Foundation
import Observation
import Sparkle

@MainActor
@Observable
final class AppUpdater {
    private let updaterController: SPUStandardUpdaterController?
    private var canCheckObservation: NSKeyValueObservation?

    var canCheckForUpdates = false

    init(bundle: Bundle = .main) {
        guard Self.isConfigured(in: bundle) else {
            updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        updaterController = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            Task { @MainActor in
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    private static func isConfigured(in bundle: Bundle) -> Bool {
        guard
            let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        else {
            return false
        }

        return !feedURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
