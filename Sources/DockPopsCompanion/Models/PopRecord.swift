import Foundation

struct PopRecord: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var name: String
}
