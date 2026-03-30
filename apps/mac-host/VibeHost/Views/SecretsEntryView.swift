import SwiftUI

/// Sheet for entering or managing per-project secrets before launch.
/// When vault entries match a secret name, shows a picker; otherwise shows a plain text field.
struct SecretsEntryView: View {
    let project: Project
    let mode: Mode
    let onComplete: (([String: String]) -> Void)?

    enum Mode { case launch, manage }

    @Environment(VaultStore.self) private var vaultStore
    @Environment(\.dismiss) private var dismiss

    // Per-secret selection: vault entry ID or nil = "type new value"
    @State private var selectedEntryId: [String: UUID?] = [:]
    // Text typed in "new value" fields
    @State private var textValues: [String: String] = [:]
    // Whether to save a new value to the vault
    @State private var saveToVault: [String: Bool] = [:]
    // Label for saving a new vault entry
    @State private var vaultLabels: [String: String] = [:]
    // Secrets currently showing their value in plain text
    @State private var revealed: Set<String> = []
    // Error shown when a save operation fails
    @State private var saveError: String?

    init(project: Project, mode: Mode, onComplete: (([String: String]) -> Void)? = nil) {
        self.project = project
        self.mode = mode
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    ForEach(project.capabilities.secrets, id: \.name) { secret in
                        secretRow(for: secret)
                    }
                }
                .padding(24)
            }
            .frame(maxHeight: 520)

            Divider()

            footer
        }
        .frame(width: 500)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear { initializeSelections() }
        .alert("Could Not Save Key", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "An unexpected error occurred while saving your key. Please try again.")
        }
    }

    // MARK: - Initialization

    private func initializeSelections() {
        for secret in project.capabilities.secrets {
            guard selectedEntryId[secret.name] == nil else { continue }
            if let bound = vaultStore.binding(packageId: project.packageCachePath, envVar: secret.name) {
                selectedEntryId[secret.name] = .some(bound.id)
            } else {
                selectedEntryId[secret.name] = .some(.none)  // "type new value"
            }
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
                Text(mode == .launch ? "API Keys Required" : "Manage Saved Keys")
                    .font(.headline)
                Text("\"\(project.appName)\" needs these keys to run. They're stored securely on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: - Secret Row

    private func secretRow(for secret: AppCapabilities.SecretMeta) -> some View {
        let matchingEntries = vaultStore.entries(for: secret.name)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Text(secret.name)
                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.primary)
                if secret.required {
                    Text("required")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                }
            }

            if !matchingEntries.isEmpty {
                vaultPickerSection(for: secret, entries: matchingEntries)
            } else {
                textInputSection(for: secret)
            }

            if let hint = secret.howToObtain {
                hintDisclosure(hint: hint)
            }
        }
    }

    // MARK: - Vault Picker

    private func vaultPickerSection(for secret: AppCapabilities.SecretMeta, entries: [VaultEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entries) { entry in
                vaultEntryOption(entry: entry, secret: secret)
            }
            newValueOption(for: secret)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private func vaultEntryOption(entry: VaultEntry, secret: AppCapabilities.SecretMeta) -> some View {
        let isSelected = selectedEntryId[secret.name] == .some(entry.id)
        let maskedValue = maskedTail(vaultStore.loadValue(for: entry))

        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .font(.system(size: 16))
                .foregroundStyle(isSelected ? .blue : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(.subheadline.weight(.medium))
                Text(maskedValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedEntryId[secret.name] = .some(entry.id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.label), \(isSelected ? "selected" : "not selected")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .padding(.vertical, 4)
    }

    private func newValueOption(for secret: AppCapabilities.SecretMeta) -> some View {
        let isSelected: Bool = {
            guard let outer = selectedEntryId[secret.name] else { return true }
            return outer == nil
        }()

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                Text("Type a new value")
                    .font(.subheadline)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selectedEntryId[secret.name] = .some(.none)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Type a new value, \(isSelected ? "selected" : "not selected")")
            .padding(.vertical, 4)

            if isSelected {
                textInputSection(for: secret)
                    .padding(.leading, 26)
            }
        }
    }

    // MARK: - Text Input

    private func textInputSection(for secret: AppCapabilities.SecretMeta) -> some View {
        let isRevealed = revealed.contains(secret.name)
        let alreadySet = SecretsManager.load(packageId: project.packageCachePath, name: secret.name) != nil
        let placeholder = alreadySet ? "already saved — type here to update" : "paste or type your key"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Group {
                    if isRevealed {
                        TextField(placeholder, text: textBinding(for: secret.name))
                    } else {
                        SecureField(placeholder, text: textBinding(for: secret.name))
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
                    revealed.formSymmetricDifference([secret.name])
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

            if !(textValues[secret.name] ?? "").isEmpty {
                saveToVaultSection(for: secret)
            }
        }
    }

    private func saveToVaultSection(for secret: AppCapabilities.SecretMeta) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: saveToVaultBinding(for: secret.name)) {
                Text("Remember this key for other apps")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)

            if saveToVault[secret.name] == true {
                TextField("Give it a name (e.g. \"Database Password\")", text: vaultLabelBinding(for: secret.name))
                    .textFieldStyle(.roundedBorder)
                    .font(.subheadline)
                    .padding(.leading, 20)
            }
        }
    }

    // MARK: - Hint Disclosure

    private func hintDisclosure(hint: String) -> some View {
        DisclosureGroup {
            Group {
                if let attributed = try? AttributedString(
                    markdown: hint,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                ) {
                    Text(attributed)
                } else {
                    Text(hint)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        } label: {
            Text("Where do I get this?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(mode == .launch ? "Launch" : "Save") {
                saveAndComplete()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(missingRequired)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - Validation

    private var missingRequired: Bool {
        project.capabilities.secrets.filter(\.required).contains { secret in
            isSecretUnresolved(secret)
        }
    }

    private func isSecretUnresolved(_ secret: AppCapabilities.SecretMeta) -> Bool {
        switch selectedEntryId[secret.name] {
        case .some(.some(let entryId)):
            // A vault entry is selected — it's resolved if the entry exists and has a value
            guard let entry = vaultStore.entries.first(where: { $0.id == entryId }) else { return true }
            return vaultStore.loadValue(for: entry) == nil
        case .some(.none), nil:
            // "Type new value" mode — resolved if text is entered or legacy keychain has a value
            let text = textValues[secret.name] ?? ""
            if !text.isEmpty { return false }
            return SecretsManager.load(packageId: project.packageCachePath, name: secret.name) == nil
        }
    }

    // MARK: - Save

    private func saveAndComplete() {
        var secrets: [String: String] = [:]
        var encounteredSaveError = false

        for secret in project.capabilities.secrets {
            switch selectedEntryId[secret.name] {
            case .some(.some(let entryId)):
                // Vault entry selected
                if let entry = vaultStore.entries.first(where: { $0.id == entryId }),
                   let value = vaultStore.loadValue(for: entry) {
                    vaultStore.setBinding(packageId: project.packageCachePath, envVar: secret.name, to: entry)
                    secrets[secret.name] = value
                }

            case .some(.none), nil:
                // "Type new value" / no vault options
                let text = textValues[secret.name] ?? ""
                if !text.isEmpty {
                    if saveToVault[secret.name] == true {
                        let rawLabel = vaultLabels[secret.name]?.trimmingCharacters(in: .whitespaces) ?? ""
                        let label = rawLabel.isEmpty ? secret.name : rawLabel
                        let newEntry = VaultEntry(label: label, envVarTags: [secret.name])
                        vaultStore.add(newEntry)
                        do {
                            try vaultStore.save(text, for: newEntry)
                            vaultStore.setBinding(packageId: project.packageCachePath, envVar: secret.name, to: newEntry)
                        } catch {
                            encounteredSaveError = true
                            saveError = "Your key could not be saved to the vault. It will work this time but you may be asked again next launch."
                        }
                    } else {
                        do {
                            try SecretsManager.save(text, packageId: project.packageCachePath, name: secret.name)
                        } catch {
                            encounteredSaveError = true
                            saveError = "Your key could not be saved to the keychain. It will work this time but you may be asked again next launch."
                        }
                    }
                    secrets[secret.name] = text
                } else if let existing = SecretsManager.load(packageId: project.packageCachePath, name: secret.name) {
                    secrets[secret.name] = existing
                }
            }
        }

        if encounteredSaveError {
            // Keep sheet open to show the error; pass secrets to caller so launch can proceed
            // once the user acknowledges.
            onComplete?(secrets)
        } else {
            dismiss()
            onComplete?(secrets)
        }
    }

    // MARK: - Helpers

    private func textBinding(for name: String) -> Binding<String> {
        Binding(get: { textValues[name] ?? "" }, set: { textValues[name] = $0 })
    }

    private func saveToVaultBinding(for name: String) -> Binding<Bool> {
        Binding(get: { saveToVault[name] ?? false }, set: { saveToVault[name] = $0 })
    }

    private func vaultLabelBinding(for name: String) -> Binding<String> {
        Binding(get: { vaultLabels[name] ?? "" }, set: { vaultLabels[name] = $0 })
    }

    private func maskedTail(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "not set" }
        let suffix = String(value.suffix(4))
        return "••••••••\(suffix)"
    }
}
