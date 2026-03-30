import SwiftUI
import os

private let logger = Logger(subsystem: "app.dotvibe.Vibe", category: "OpenPackage")

/// Sheet modal displayed when opening a .vibeapp package.
struct OpenPackageView: View {
    let packageURL: URL
    @Bindable var store: ProjectStore
    let onImported: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var vibePackage: VibePackage?
    @State private var packageData: Data?
    @State private var trustResult: PackageVerifier.TrustVerificationResult?
    @State private var capabilities: AppCapabilities?
    @State private var errorMessage: String?
    @State private var errorDetail: String?
    @State private var showErrorAlert = false

    private var trustStatus: TrustStatus { trustResult?.status ?? .unsigned }

    var body: some View {
        VStack(spacing: 0) {
            if let error = errorMessage {
                errorView(error)
            } else if let pkg = vibePackage {
                packageInfo(pkg)
            } else {
                ProgressView("Loading package…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            buttons
        }
        .frame(width: 420, height: 480)
        .task {
            await loadPackage()
        }
        .alert("Technical Details", isPresented: $showErrorAlert) {
            Button("Copy to Clipboard") {
                if let detail = errorDetail {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorDetail ?? "No additional details available.")
        }
    }

    private func packageInfo(_ pkg: VibePackage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: "app.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(pkg.appManifest.name ?? pkg.packageManifest.appId)
                            .font(.title2.weight(.semibold))
                        Text("v\(pkg.packageManifest.appVersion)")
                            .foregroundStyle(.secondary)
                        if let publisher = pkg.appManifest.publisher?.name {
                            Text(publisher)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                Divider()

                // Trust status
                HStack {
                    Text("Trust Status")
                        .fontWeight(.medium)
                    Spacer()
                    TrustBadge(status: trustStatus)
                }

                // TOFU prompt: shown when the publisher key is valid but not yet trusted.
                if trustStatus == .newPublisher, let result = trustResult,
                   let fingerprint = result.keyFingerprint {
                    Divider()
                    trustPrompt(
                        publisherName: result.publisherName ?? pkg.appManifest.publisher?.name ?? "Unknown Publisher",
                        fingerprint: fingerprint
                    )
                }

                Divider()

                // Capabilities
                if let caps = capabilities {
                    Text("Capabilities")
                        .fontWeight(.medium)

                    VStack(spacing: 6) {
                        CapabilityRow(
                            icon: "globe",
                            label: "Network Access",
                            value: caps.network ? "Yes" : "No"
                        )
                        CapabilityRow(
                            icon: "folder",
                            label: "Host File Import",
                            value: caps.allowHostFileImport ? "Yes" : "No"
                        )
                        if !caps.exposedPorts.isEmpty {
                            CapabilityRow(
                                icon: "number.circle",
                                label: "Exposed Ports",
                                value: caps.exposedPorts.map(String.init).joined(separator: ", ")
                            )
                        }
                        if !caps.requiredSecrets.isEmpty {
                            CapabilityRow(
                                icon: "key",
                                label: "Required Secrets",
                                value: caps.requiredSecrets.joined(separator: ", ")
                            )
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func trustPrompt(publisherName: String, fingerprint: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("New Publisher", systemImage: "questionmark.circle.fill")
                .foregroundStyle(.orange)
                .fontWeight(.medium)

            Text("This app is signed by a publisher you haven't trusted before. The signature is cryptographically valid — the package hasn't been tampered with — but you haven't verified who owns this key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Publisher")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(publisherName)
                        .font(.caption.weight(.medium))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Key fingerprint")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(PublisherTrustStore.shortFingerprint(from: fingerprint))
                        .font(.system(.caption, design: .monospaced).weight(.medium))
                }
            }

            Button {
                PublisherTrustStore.shared.trust(fingerprint: fingerprint, publisherName: publisherName)
                // Refresh trust status to .trustedByUser so the badge updates immediately.
                if let result = trustResult {
                    trustResult = PackageVerifier.TrustVerificationResult(
                        status: .trustedByUser,
                        publisherKeyData: result.publisherKeyData,
                        publisherName: result.publisherName
                    )
                }
            } label: {
                Label("Trust Publisher", systemImage: "checkmark.shield")
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
            .controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.red)
            Text("Failed to Open Package")
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if errorDetail != nil {
                Button("Show Full Error") {
                    showErrorAlert = true
                }
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var buttons: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Open") {
                importAndDismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(vibePackage == nil || errorMessage != nil || trustStatus == .tampered)
        }
        .padding()
    }

    private func loadPackage() async {
        logger.info("Loading package from: \(self.packageURL.path)")
        do {
            var data = try Data(contentsOf: packageURL)

            if PackageDecryption.isEncrypted(data) {
                logger.info("Package is encrypted, prompting for password")
                guard let password = PackageDecryption.promptPassword(forPackage: packageURL.lastPathComponent) else {
                    throw PackageDecryption.DecryptError.cancelled
                }
                data = try PackageDecryption.decrypt(data, password: password)
            }

            let pkg = try PackageExtractor.extract(data: data)
            logger.info("Extracted package: \(pkg.packageManifest.appId)")
            let result = PackageVerifier.verifyTrust(package: pkg, vibeRootKey: store.vibeOfficialPublicKey)
            logger.info("Trust status: \(result.status.rawValue)")
            self.packageData = data
            self.trustResult = result
            self.capabilities = AppCapabilities(from: pkg.appManifest)
            self.vibePackage = pkg
        } catch {
            // User cancelled the password prompt — close the sheet silently.
            if case PackageDecryption.DecryptError.cancelled = error {
                logger.info("Password prompt cancelled by user")
                dismiss()
                return
            }
            let detail = String(describing: error)
            logger.error("Package load FAILED: \(detail)")
            self.errorDetail = "File: \(packageURL.lastPathComponent)\n\n\(detail)"
            self.errorMessage = friendlyErrorMessage(for: error)
        }
    }

    private func importAndDismiss() {
        logger.info("Importing package from: \(self.packageURL.path)")
        do {
            guard let data = packageData else { return }
            let project = try store.importPackage(data: data, from: packageURL)
            logger.info("Import succeeded: \(project.appName)")
            onImported(project)
            dismiss()
        } catch {
            let detail = String(describing: error)
            self.errorDetail = "Import error:\n\n\(detail)"
            self.errorMessage = friendlyErrorMessage(for: error)
        }
    }

    /// Translates technical errors into plain language for non-technical users.
    private func friendlyErrorMessage(for error: Error) -> String {
        let desc = String(describing: error).lowercased()
        if desc.contains("password") || desc.contains("decrypt") || desc.contains("cipher") {
            return "The password you entered is incorrect. Please try again."
        }
        if desc.contains("zip") || desc.contains("archive") || desc.contains("corrupt") {
            return "This file doesn't appear to be a valid Vibe app. It may be damaged or incomplete."
        }
        if desc.contains("notfound") || desc.contains("no such file") {
            return "The file could not be found. It may have been moved or deleted."
        }
        return "This file could not be opened. It may be damaged or incompatible with this version of Vibe."
    }
}
