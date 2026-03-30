import SwiftUI

/// Sheet for adding or editing a vault entry.
struct VaultEntryEditView: View {
    @Environment(VaultStore.self) private var vaultStore
    @Environment(\.dismiss) private var dismiss

    let existingEntry: VaultEntry?

    @State private var label: String
    @State private var notes: String
    @State private var envVarTags: [String]
    @State private var newTagText = ""
    @State private var valueText: String
    @State private var isRevealed = false
    @State private var saveError: String?

    init(entry: VaultEntry? = nil) {
        self.existingEntry = entry
        _label = State(initialValue: entry?.label ?? "")
        _notes = State(initialValue: entry?.notes ?? "")
        _envVarTags = State(initialValue: entry?.envVarTags ?? [])
        // Load existing value for editing
        if let entry {
            _valueText = State(initialValue: SecretsManager.loadVaultEntry(id: entry.id.uuidString) ?? "")
        } else {
            _valueText = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    nameField
                    notesField
                    envVarTagsSection
                    valueField
                }
                .padding(24)
            }

            Divider()

            footer
        }
        .frame(width: 460)
        .fixedSize(horizontal: true, vertical: true)
        .alert("Could Not Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "Your key could not be saved. Please try again.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.blue.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: "key.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(existingEntry == nil ? "New Saved Key" : "Edit Saved Key")
                    .font(.headline)
                Text("Stored securely in your Keychain")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: - Fields

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Name")
                .font(.subheadline.weight(.medium))
            TextField("e.g. Database Password", text: $label)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var notesField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Notes")
                .font(.subheadline.weight(.medium))
            TextField("Optional description", text: $notes)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var envVarTagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Variable Names")
                    .font(.subheadline.weight(.medium))
                Text("Apps that request secrets by any of these names will use this saved key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(envVarTags.indices, id: \.self) { idx in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("VARIABLE_NAME", text: $envVarTags[idx])
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        if !envVarTags[idx].isEmpty && !isValidEnvVarName(envVarTags[idx]) {
                            Text("Use only letters, numbers, and underscores (no spaces or hyphens).")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    Button {
                        envVarTags.remove(at: idx)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                    .accessibilityLabel("Remove \(envVarTags[idx])")
                }
            }

            HStack(spacing: 8) {
                TextField("Add a variable name…", text: $newTagText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { addTag() }
                Button {
                    addTag()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .help("Add variable name")
                .accessibilityLabel("Add variable name")
                .disabled(newTagText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var valueField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Value")
                .font(.subheadline.weight(.medium))

            HStack(spacing: 0) {
                Group {
                    if isRevealed {
                        TextField(existingEntry != nil ? "type new value to update" : "paste or type", text: $valueText)
                    } else {
                        SecureField(existingEntry != nil ? "type new value to update" : "paste or type", text: $valueText)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(.body, design: isRevealed ? .monospaced : .default))
                .frame(maxWidth: .infinity)
                .padding(.leading, 10)
                .padding(.vertical, 9)

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
                .help(isRevealed ? "Hide value" : "Show value")
                .accessibilityLabel(isRevealed ? "Hide key value" : "Show key value")
                .accessibilityHint("Toggles whether the key is shown as plain text or hidden")
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 1)
            )
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { saveEntry() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var canSave: Bool {
        !label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !envVarTags.filter({ !$0.trimmingCharacters(in: .whitespaces).isEmpty }).isEmpty
    }

    // MARK: - Validation

    /// Returns true if the name is a valid shell variable name (letters, digits, underscores; not starting with a digit).
    private func isValidEnvVarName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let pattern = "^[A-Za-z_][A-Za-z0-9_]*$"
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: - Actions

    private func addTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        envVarTags.append(trimmed)
        newTagText = ""
    }

    private func saveEntry() {
        let cleanTags = envVarTags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let cleanLabel = label.trimmingCharacters(in: .whitespaces)

        if let existing = existingEntry {
            var updated = existing
            updated.label = cleanLabel
            updated.notes = notes
            updated.envVarTags = cleanTags
            vaultStore.update(updated)
            if !valueText.isEmpty {
                do {
                    try vaultStore.save(valueText, for: updated)
                } catch {
                    saveError = "Your key details were saved but the secret value could not be stored in the Keychain. Please try again."
                    return
                }
            }
        } else {
            let entry = VaultEntry(label: cleanLabel, notes: notes, envVarTags: cleanTags)
            vaultStore.add(entry)
            if !valueText.isEmpty {
                do {
                    try vaultStore.save(valueText, for: entry)
                } catch {
                    saveError = "Your key details were saved but the secret value could not be stored in the Keychain. Please try again."
                    return
                }
            }
        }
        dismiss()
    }
}
