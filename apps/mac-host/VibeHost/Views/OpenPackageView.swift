import SwiftUI
import os

private let logger = Logger(subsystem: "ninja.gil.VibeHost", category: "OpenPackage")

/// Sheet modal displayed when opening a .vibeapp package.
struct OpenPackageView: View {
    let packageURL: URL
    @Bindable var store: ProjectStore
    let onImported: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var vibePackage: VibePackage?
    @State private var trustStatus: TrustStatus = .unsigned
    @State private var capabilities: AppCapabilities?
    @State private var errorMessage: String?
    @State private var errorDetail: String?
    @State private var showErrorAlert = false

    var body: some View {
        VStack(spacing: 0) {
            if let error = errorMessage {
                errorView(error)
            } else if let pkg = vibePackage {
                packageInfo(pkg)
            } else {
                ProgressView("Loading package...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            buttons
        }
        .frame(width: 420, height: 480)
        .task {
            await loadPackage()
        }
        .alert("Error Details", isPresented: $showErrorAlert) {
            Button("Copy to Clipboard") {
                if let detail = errorDetail {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(detail, forType: .string)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorDetail ?? "Unknown error")
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
            .disabled(vibePackage == nil || errorMessage != nil)
        }
        .padding()
    }

    private func loadPackage() async {
        logger.error("Loading package from: \(self.packageURL.path)")
        do {
            let pkg = try PackageExtractor.extract(from: packageURL)
            logger.info("Extracted package: \(pkg.packageManifest.appId)")
            let key = store.demoPublicKey
            logger.info("Demo public key available: \(key != nil)")
            self.trustStatus = PackageVerifier.verifyTrust(package: pkg, publicKey: key)
            self.capabilities = AppCapabilities(from: pkg.appManifest)
            self.vibePackage = pkg
            logger.info("Package loaded successfully")
        } catch {
            let detail = String(describing: error)
            logger.error("Package load FAILED: \(detail)")
            self.errorDetail = "URL: \(packageURL.path)\n\n\(detail)"
            self.errorMessage = error.localizedDescription
        }
    }

    private func importAndDismiss() {
        logger.error("Importing package from: \(self.packageURL.path)")
        do {
            let project = try store.importPackage(from: packageURL)
            logger.info("Import succeeded: \(project.appName)")
            onImported(project)
            dismiss()
        } catch {
            let detail = String(describing: error)
            self.errorDetail = "Import error:\n\n\(detail)"
            self.errorMessage = error.localizedDescription
        }
    }
}
