import SwiftUI

/// Window showing all vault entries with search, add, edit, and delete.
struct VaultView: View {
    @Environment(VaultStore.self) private var vaultStore
    @State private var searchText = ""
    @State private var editingEntry: VaultEntry? = nil
    @State private var isAddingNew = false
    @State private var confirmDelete: VaultEntry? = nil
    @State private var showCopiedToast = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                searchBar

                Divider()

                if filteredEntries.isEmpty {
                    emptyState
                } else {
                    entryList
                }
            }

            // "Copied" toast overlay
            if showCopiedToast {
                VStack {
                    Spacer()
                    Text("Copied to clipboard")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.75), in: Capsule())
                        .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showCopiedToast)
        .frame(minWidth: 520, minHeight: 400)
        .navigationTitle("Saved Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isAddingNew = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add new saved key")
                .accessibilityLabel("Add saved key")
            }
        }
        .sheet(isPresented: $isAddingNew) {
            VaultEntryEditView(entry: nil)
        }
        .sheet(item: $editingEntry) { entry in
            VaultEntryEditView(entry: entry)
        }
        .alert("Delete This Key?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let entry = confirmDelete {
                    vaultStore.delete(entry)
                }
                confirmDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmDelete = nil }
        } message: {
            if let entry = confirmDelete {
                let usageCount = vaultStore.usageCount(for: entry)
                if usageCount > 0 {
                    Text("\"\(entry.label)\" will be permanently deleted. The \(usageCount == 1 ? "app using it" : "\(usageCount) apps using it") will ask you for this key again next time.")
                } else {
                    Text("\"\(entry.label)\" will be permanently deleted.")
                }
            }
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search…", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Entry List

    private var entryList: some View {
        List {
            ForEach(filteredEntries) { entry in
                entryRow(entry)
                    .contextMenu {
                        Button("Edit…") { editingEntry = entry }
                        Button("Copy Value") { copyValue(entry) }
                        Divider()
                        Button("Delete", role: .destructive) { confirmDelete = entry }
                    }
            }
        }
        .listStyle(.plain)
    }

    private func entryRow(_ entry: VaultEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.blue.opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: "key.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(entry.label)
                        .font(.subheadline.weight(.semibold))
                    Text(maskedTail(for: entry))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(entry.envVarTags.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            usageBadge(for: entry)
        }
        .padding(.vertical, 4)
    }

    private func usageBadge(for entry: VaultEntry) -> some View {
        let count = vaultStore.usageCount(for: entry)
        let text = count == 0 ? "Unused" : count == 1 ? "1 app" : "\(count) apps"
        let color: Color = count == 0 ? .secondary : .blue

        return Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(count == 0 ? Color.secondary : Color.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(count == 0 ? Color.clear : color, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(count == 0 ? Color.secondary.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .accessibilityLabel(count == 0 ? "Not used by any apps" : count == 1 ? "Used by 1 app" : "Used by \(count) apps")
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty ? "No Saved Keys Yet" : "No Results")
                .font(.title3.weight(.semibold))
            Text(
                searchText.isEmpty
                    ? "Add API keys and credentials here to reuse them across apps."
                    : "No saved keys match \"\(searchText)\""
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 300)
            if searchText.isEmpty {
                Button("Add a Key") { isAddingNew = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Helpers

    private var filteredEntries: [VaultEntry] {
        guard !searchText.isEmpty else { return vaultStore.entries }
        let query = searchText.lowercased()
        return vaultStore.entries.filter {
            $0.label.lowercased().contains(query) ||
            $0.envVarTags.contains { $0.lowercased().contains(query) }
        }
    }

    private func maskedTail(for entry: VaultEntry) -> String {
        guard let value = vaultStore.loadValue(for: entry), !value.isEmpty else { return "••••••••" }
        let suffix = String(value.suffix(4))
        return "••••••••\(suffix)"
    }

    private func copyValue(_ entry: VaultEntry) {
        guard let value = vaultStore.loadValue(for: entry) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showCopiedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedToast = false
        }
    }
}
