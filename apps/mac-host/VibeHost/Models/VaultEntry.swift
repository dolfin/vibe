import Foundation

struct VaultEntry: Identifiable, Codable {
    let id: UUID
    var label: String        // "Database Password"
    var notes: String        // optional free text
    var envVarTags: [String] // ["DB_PASSWORD", "DATABASE_URL"] — any match satisfies a request
    let createdAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        notes: String = "",
        envVarTags: [String],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.label = label
        self.notes = notes
        self.envVarTags = envVarTags
        self.createdAt = createdAt
    }
}
