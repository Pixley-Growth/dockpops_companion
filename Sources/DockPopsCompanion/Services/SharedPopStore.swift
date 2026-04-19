import Foundation

struct SharedPopStore {
    private struct SharedGroupMeta: Codable {
        let id: UUID
        let name: String
    }

    func loadPops(from shortcutGroupsURL: URL) throws -> [PopRecord] {
        let data = try Data(contentsOf: shortcutGroupsURL)
        let groups = try JSONDecoder().decode([SharedGroupMeta].self, from: data)
        return groups.map { meta in
            PopRecord(id: meta.id, name: meta.name.trimmedOrNil ?? "Untitled Pop")
        }
    }
}
