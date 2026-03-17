import Foundation
import Observation

/// Global reusable credential store. Entries are persisted as JSON in UserDefaults;
/// secret values are stored in Keychain under "vault.{entryId}" keys.
@Observable
final class VaultStore {
    private(set) var entries: [VaultEntry] = []

    private let entriesKey = "vibe.vault.entries"
    private let bindingsKey = "vibe.vault.bindings"

    init() {
        load()
    }

    // MARK: - Entry CRUD

    func add(_ entry: VaultEntry) {
        entries.append(entry)
        persist()
    }

    func update(_ entry: VaultEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        persist()
    }

    func delete(_ entry: VaultEntry) {
        SecretsManager.deleteVaultEntry(id: entry.id.uuidString)
        var bindings = loadBindings()
        bindings = bindings.filter { $0.value != entry.id.uuidString }
        saveBindings(bindings)
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// All entries whose envVarTags contain the given tag.
    func entries(for envVarTag: String) -> [VaultEntry] {
        entries.filter { $0.envVarTags.contains(envVarTag) }
    }

    // MARK: - Value Storage

    func save(_ value: String, for entry: VaultEntry) throws {
        try SecretsManager.saveVaultEntry(value, id: entry.id.uuidString)
    }

    func loadValue(for entry: VaultEntry) -> String? {
        SecretsManager.loadVaultEntry(id: entry.id.uuidString)
    }

    // MARK: - Bindings

    /// Returns the vault entry previously bound to (packageId, envVar), if it still exists.
    func binding(packageId: String, envVar: String) -> VaultEntry? {
        let bindings = loadBindings()
        let key = bindingKey(packageId: packageId, envVar: envVar)
        guard let uuidString = bindings[key],
              let uuid = UUID(uuidString: uuidString) else { return nil }
        return entries.first { $0.id == uuid }
    }

    func setBinding(packageId: String, envVar: String, to entry: VaultEntry?) {
        var bindings = loadBindings()
        let key = bindingKey(packageId: packageId, envVar: envVar)
        if let entry {
            bindings[key] = entry.id.uuidString
        } else {
            bindings.removeValue(forKey: key)
        }
        saveBindings(bindings)
    }

    /// Number of (packageId, envVar) pairs currently bound to this entry.
    func usageCount(for entry: VaultEntry) -> Int {
        loadBindings().values.filter { $0 == entry.id.uuidString }.count
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: entriesKey),
              let decoded = try? JSONDecoder().decode([VaultEntry].self, from: data) else { return }
        entries = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: entriesKey)
    }

    private func loadBindings() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: bindingsKey) as? [String: String] ?? [:]
    }

    private func saveBindings(_ bindings: [String: String]) {
        UserDefaults.standard.set(bindings, forKey: bindingsKey)
    }

    private func bindingKey(packageId: String, envVar: String) -> String {
        "\(packageId).\(envVar)"
    }
}
