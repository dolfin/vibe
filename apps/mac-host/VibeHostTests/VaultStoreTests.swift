import XCTest
@testable import VibeHost

final class VaultStoreTests: XCTestCase {

    private let entriesKey = "vibe.vault.entries"
    private let bindingsKey = "vibe.vault.bindings"

    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: entriesKey)
        UserDefaults.standard.removeObject(forKey: bindingsKey)
    }

    private func makeEntry(label: String, tags: [String] = ["TAG"]) -> VaultEntry {
        VaultEntry(id: UUID(), label: label, notes: "", envVarTags: tags, createdAt: Date())
    }

    // MARK: - add / entries

    func testAddAppendsEntry() {
        let store = VaultStore()
        let entry = makeEntry(label: "Test Entry")
        store.add(entry)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.label, "Test Entry")
    }

    func testAddMultipleEntries() {
        let store = VaultStore()
        store.add(makeEntry(label: "A"))
        store.add(makeEntry(label: "B"))
        store.add(makeEntry(label: "C"))
        XCTAssertEqual(store.entries.count, 3)
    }

    // MARK: - update

    func testUpdateModifiesEntry() {
        let store = VaultStore()
        var entry = makeEntry(label: "Original")
        store.add(entry)
        entry.label = "Updated"
        store.update(entry)
        XCTAssertEqual(store.entries.first?.label, "Updated")
    }

    func testUpdateNonExistentEntryDoesNothing() {
        let store = VaultStore()
        store.add(makeEntry(label: "Existing"))
        let unknownEntry = makeEntry(label: "Unknown")
        store.update(unknownEntry)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries.first?.label, "Existing")
    }

    // MARK: - entries(for:)

    func testEntriesForTagFiltersCorrectly() {
        let store = VaultStore()
        store.add(makeEntry(label: "OpenAI Key", tags: ["OPENAI_API_KEY", "OPENAI_KEY"]))
        store.add(makeEntry(label: "Stripe Key", tags: ["STRIPE_SECRET"]))
        store.add(makeEntry(label: "Another OpenAI", tags: ["OPENAI_API_KEY"]))

        let results = store.entries(for: "OPENAI_API_KEY")
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.envVarTags.contains("OPENAI_API_KEY") })
    }

    func testEntriesForTagReturnsEmptyWhenNoMatch() {
        let store = VaultStore()
        store.add(makeEntry(label: "Stripe Key", tags: ["STRIPE_SECRET"]))
        let results = store.entries(for: "NONEXISTENT_TAG")
        XCTAssertTrue(results.isEmpty)
    }

    func testEntriesForTagReturnsEmptyWhenStoreEmpty() {
        let store = VaultStore()
        XCTAssertTrue(store.entries(for: "ANY_TAG").isEmpty)
    }

    // MARK: - setBinding / binding

    func testSetAndGetBinding() {
        let store = VaultStore()
        let entry = makeEntry(label: "My API Key")
        store.add(entry)
        store.setBinding(packageId: "com.example", envVar: "API_KEY", to: entry)
        let bound = store.binding(packageId: "com.example", envVar: "API_KEY")
        XCTAssertEqual(bound?.id, entry.id)
    }

    func testBindingReturnsNilWhenNotSet() {
        let store = VaultStore()
        let result = store.binding(packageId: "com.example", envVar: "UNSET_VAR")
        XCTAssertNil(result)
    }

    func testSetBindingToNilClearsBinding() {
        let store = VaultStore()
        let entry = makeEntry(label: "Key")
        store.add(entry)
        store.setBinding(packageId: "com.pkg", envVar: "MY_VAR", to: entry)
        store.setBinding(packageId: "com.pkg", envVar: "MY_VAR", to: nil)
        XCTAssertNil(store.binding(packageId: "com.pkg", envVar: "MY_VAR"))
    }

    func testBindingIsScopedToPackageAndVar() {
        let store = VaultStore()
        let entry1 = makeEntry(label: "Key 1")
        let entry2 = makeEntry(label: "Key 2")
        store.add(entry1)
        store.add(entry2)
        store.setBinding(packageId: "com.pkg1", envVar: "VAR", to: entry1)
        store.setBinding(packageId: "com.pkg2", envVar: "VAR", to: entry2)

        XCTAssertEqual(store.binding(packageId: "com.pkg1", envVar: "VAR")?.id, entry1.id)
        XCTAssertEqual(store.binding(packageId: "com.pkg2", envVar: "VAR")?.id, entry2.id)
    }

    func testBindingReturnsNilWhenEntryNoLongerExists() {
        let store = VaultStore()
        let entry = makeEntry(label: "Temp Key")
        store.add(entry)
        store.setBinding(packageId: "com.pkg", envVar: "VAR", to: entry)
        store.delete(entry)
        // After deletion the binding key is cleaned up too
        XCTAssertNil(store.binding(packageId: "com.pkg", envVar: "VAR"))
    }

    // MARK: - usageCount

    func testUsageCountZeroWhenNoBound() {
        let store = VaultStore()
        let entry = makeEntry(label: "Key")
        store.add(entry)
        XCTAssertEqual(store.usageCount(for: entry), 0)
    }

    func testUsageCountIncrementsPerBinding() {
        let store = VaultStore()
        let entry = makeEntry(label: "Shared Key")
        store.add(entry)
        store.setBinding(packageId: "com.pkg1", envVar: "VAR_A", to: entry)
        store.setBinding(packageId: "com.pkg2", envVar: "VAR_B", to: entry)
        store.setBinding(packageId: "com.pkg1", envVar: "VAR_C", to: entry)
        XCTAssertEqual(store.usageCount(for: entry), 3)
    }

    // MARK: - delete

    func testDeleteRemovesEntry() {
        let store = VaultStore()
        let entry = makeEntry(label: "To Delete")
        store.add(entry)
        store.delete(entry)
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDeleteNonexistentEntryIsNoop() {
        let store = VaultStore()
        store.add(makeEntry(label: "Keep"))
        let ghost = makeEntry(label: "Ghost")
        store.delete(ghost)
        XCTAssertEqual(store.entries.count, 1)
    }

    // MARK: - persistence across instances

    func testEntriesPersistedAcrossStoreInstances() {
        let entry = makeEntry(label: "Persistent Key", tags: ["MY_VAR"])
        do {
            let store = VaultStore()
            store.add(entry)
        }
        let store2 = VaultStore()
        XCTAssertEqual(store2.entries.count, 1)
        XCTAssertEqual(store2.entries.first?.label, "Persistent Key")
    }
}
