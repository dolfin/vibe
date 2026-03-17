import SwiftUI

/// Sheet for entering or managing per-project secrets before launch.
struct SecretsEntryView: View {
    let project: Project
    let mode: Mode
    let onComplete: (([String: String]) -> Void)?

    enum Mode { case launch, manage }

    @State private var values: [String: String] = [:]
    @State private var revealed: Set<String> = []
    @Environment(\.dismiss) private var dismiss

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
            .frame(maxHeight: 480)

            Divider()

            footer
        }
        .frame(width: 480)
        .fixedSize(horizontal: true, vertical: true)
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
                Text(mode == .launch ? "Secrets Required" : "Manage Secrets")
                    .font(.headline)
                Text("\"\(project.appName)\" requires API keys to run.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    // MARK: - Secret row

    private func secretRow(for secret: AppCapabilities.SecretMeta) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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

            inputField(for: secret)

            if let hint = secret.howToObtain {
                hintDisclosure(hint: hint)
            }
        }
    }

    // MARK: - Input field

    private func inputField(for secret: AppCapabilities.SecretMeta) -> some View {
        let isRevealed = revealed.contains(secret.name)
        let alreadySet = SecretsManager.load(packageId: project.packageCachePath, name: secret.name) != nil
        let placeholder = alreadySet ? "already set — enter to replace" : "paste or type value"

        return HStack(spacing: 0) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: binding(for: secret.name))
                } else {
                    SecureField(placeholder, text: binding(for: secret.name))
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
            .help(isRevealed ? "Hide" : "Show")
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    // MARK: - Hint disclosure

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
            Text("How to obtain")
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

    /// True if any required secret has neither a stored value nor a freshly entered one.
    private var missingRequired: Bool {
        project.capabilities.secrets.filter(\.required).contains { secret in
            let stored = SecretsManager.load(packageId: project.packageCachePath, name: secret.name) != nil
            let entered = !(values[secret.name] ?? "").isEmpty
            return !stored && !entered
        }
    }

    // MARK: - Helpers

    private func binding(for name: String) -> Binding<String> {
        Binding(get: { values[name] ?? "" }, set: { values[name] = $0 })
    }

    private func saveAndComplete() {
        for (name, value) in values where !value.isEmpty {
            try? SecretsManager.save(value, packageId: project.packageCachePath, name: name)
        }
        let secrets = SecretsManager.loadAll(
            packageId: project.packageCachePath,
            names: project.capabilities.declaredSecrets
        )
        dismiss()
        onComplete?(secrets)
    }
}
