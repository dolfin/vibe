import SwiftUI
import AppKit

struct DeveloperCommands: Commands {
    @FocusedValue(\.vibeDocumentContext) private var documentContext: VibeDocumentContext?

    var body: some Commands {
        CommandMenu("Developer") {
            Button("Clear Caches…") {
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Clear All Caches?"
                    alert.informativeText = "This stops the VM and deletes the package cache and Docker image cache (data.img). The app package cache is also cleared. Next boot will re-download everything."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Clear Caches")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    await VMManager.shared.clearCaches()
                }
            }

            Divider()

            Button("Revert to Original State…") {
                Task { @MainActor in
                    let alert = NSAlert()
                    alert.messageText = "Revert to Original State?"
                    alert.informativeText = "This removes all saved state for this app. The next time you open the app, it will start fresh (or from seeded initial state if present)."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Revert")
                    alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    guard let ctx = documentContext else { return }
                    await ctx.revert()
                }
            }
            .disabled(documentContext == nil)

            Divider()

            Button("Open VM Console Log") {
                Task { @MainActor in
                    NSWorkspace.shared.open(VMManager.shared.consoleLogURL)
                }
            }
        }
    }
}
