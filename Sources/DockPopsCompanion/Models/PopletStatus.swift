import Foundation

enum PopletIconSource: String, Hashable, Sendable {
    case popComposite = "Pop icon"
    case dockPopsApp = "DockPops icon"
    case generic = "Generic icon"
}

struct PopletStatus: Hashable, Identifiable, Sendable {
    let popID: UUID
    let popName: String
    let popletURL: URL
    let iconSource: PopletIconSource

    var id: UUID { popID }
}

struct SyncStats: Hashable, Sendable {
    var created = 0
    var updated = 0
    var renamed = 0
    var removed = 0

    static let zero = SyncStats()

    var summary: String {
        "Created \(created), updated \(updated), renamed \(renamed), removed \(removed)"
    }
}

struct SyncSnapshot: Sendable {
    var pops: [PopRecord]
    var poplets: [PopletStatus]
    var stats: SyncStats
    var hasSharedContainerAccess: Bool
    var metadataAvailable: Bool
    var dockPopsFound: Bool
    var errorDescription: String?
}
