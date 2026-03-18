import SwiftUI
import UniformTypeIdentifiers

struct GetStartedView: View {
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(nsColor: .systemBlue).opacity(0.8), Color(nsColor: .systemIndigo)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Create a Vibe App")
                        .font(.title2.weight(.semibold))
                    Text("Use the Vibe CLI to turn any project into a self-contained app you can open here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()

            // Steps
            VStack(spacing: 0) {
                StepRow(
                    number: 1,
                    icon: "terminal",
                    title: "Install",
                    command: "brew tap dolfin/vibe && brew install vibe"
                )
                StepRow(
                    number: 2,
                    icon: "doc.text",
                    title: "Define",
                    command: "vibe init myapp"
                )
                StepRow(
                    number: 3,
                    icon: "shippingbox",
                    title: "Package",
                    command: "vibe package vibe.yaml -o myapp.vibeapp"
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            // Footer
            HStack {
                Button {
                    openTerminal()
                } label: {
                    Label("Open Terminal", systemImage: "terminal")
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                Spacer()

                Button {
                    openVibeApp()
                } label: {
                    Text("Open .vibeapp\u{2026}")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 560, height: 330)
    }
    
    @available(OSX 10.15, *)
    private func openTerminal(at url: URL? = nil) {
        guard let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return
        }
        
        let configuration = NSWorkspace.OpenConfiguration()
        
        if let url = url {
            NSWorkspace.shared.open([url], withApplicationAt: appUrl, configuration: configuration)
        } else {
            NSWorkspace.shared.open(appUrl)
        }
    }

    private func openVibeApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("ninja.gil.vibe.vibeapp")!]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a .vibeapp package to open"

        if panel.runModal() == .OK, let url = panel.url {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }
}

// MARK: - StepRow

private struct StepRow: View {
    let number: Int
    let icon: String
    let title: String
    let command: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // Number badge
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 22)
                Text("\(number)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }

            // Icon + Title
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.medium))
                .frame(width: 90, alignment: .leading)

            // Command capsule
            CommandCapsule(command: command)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - CommandCapsule

private struct CommandCapsule: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                withAnimation(.easeInOut(duration: 0.15)) {
                    copied = true
                }
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    withAnimation(.easeInOut(duration: 0.15)) {
                        copied = false
                    }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? .green : .secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Copy command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quaternary)
        )
    }
}

#Preview {
    GetStartedView()
}
