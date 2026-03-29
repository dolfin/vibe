import SwiftUI
import AppKit

// MARK: - LibraryView

struct LibraryView: View {
    @Bindable var store: ProjectStore

    private var favorites: [Project] {
        store.projects
            .filter { $0.isFavorite }
            .sorted { $0.appName.localizedCompare($1.appName) == .orderedAscending }
    }

    private var recentProjects: [Project] {
        store.projects
            .filter { !$0.isFavorite }
            .sorted { ($0.lastOpenedAt ?? $0.importedAt) > ($1.lastOpenedAt ?? $1.importedAt) }
    }

    var body: some View {
        List {
            if !favorites.isEmpty {
                Section {
                    ForEach(favorites) { AppRow(project: $0, showPath: false, store: store) }
                } header: {
                    SectionHeader("Favorites")
                }
            }

            if !recentProjects.isEmpty {
                Section {
                    ForEach(recentProjects) { AppRow(project: $0, showPath: true, store: store) }
                } header: {
                    SectionHeader("Recently Opened")
                }
            }

            if store.projects.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No apps yet")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Browse for a .vibeapp file to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(minWidth: 320, minHeight: 400)
    }
}

// MARK: - Section Header

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(.caption, design: .default, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }
}

// MARK: - App Row

private struct AppRow: View {
    let project: Project
    let showPath: Bool
    var store: ProjectStore

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(project: project)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.appName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 3) {
                    if let publisher = project.publisher {
                        Text(publisher)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    if project.trustStatus == .verified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .help("Cryptographically verified")
                    }
                }

                if showPath, let path = project.displayPath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { openProject(project) }
        .onHover { isHovered = $0 }
        .listRowBackground(
            isHovered
                ? Color(NSColor.selectedContentBackgroundColor).opacity(0.08)
                : Color.clear
        )
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .contextMenu {
            if project.isFavorite {
                Button("Remove from Favorites") {
                    store.setFavorite(project, to: false)
                }
            } else {
                Button("Add to Favorites") {
                    store.setFavorite(project, to: true)
                }
            }
            Divider()
            Button("Remove from Library", role: .destructive) {
                store.removeProject(project)
            }
        }
    }

    private func openProject(_ project: Project) {
        let cacheURL = StorageManager.packageCacheDir
            .appendingPathComponent(project.packageCachePath)
            .appendingPathComponent("package.vibeapp")

        if let originalPath = project.originalPackagePath,
           !originalPath.contains(Bundle.main.bundlePath) {
            let originalURL = URL(fileURLWithPath: originalPath)
            NSDocumentController.shared.openDocument(withContentsOf: originalURL, display: true) { _, _, error in
                guard error != nil else { return }
                DispatchQueue.main.async {
                    NSDocumentController.shared.openDocument(withContentsOf: cacheURL, display: true) { _, _, _ in }
                }
            }
        } else {
            NSDocumentController.shared.openDocument(withContentsOf: cacheURL, display: true) { _, _, _ in }
        }
    }
}

// MARK: - App Icon

struct AppIconView: View {
    let project: Project

    @State private var customIcon: NSImage?
    @State private var hatNSImage: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if let customIcon {
                Image(nsImage: customIcon)
                    .resizable()
                    .scaledToFill()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                tintedFallback
            }
        }
        .task(id: project.packageCachePath) {
            let url = StorageManager.iconURL(for: project.packageCachePath)
            customIcon = (try? Data(contentsOf: url)).flatMap { NSImage(data: $0) }
        }
        .task(id: colorScheme == .dark) {
            let name = colorScheme == .dark ? "hat-dark" : "hat-light"
            guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return }
            hatNSImage = NSImage(contentsOf: url)
        }
    }

    /// Fallback: hat image used as a luminance mask over a solid tint — same approach iOS uses
    /// for tinted template icons. Bright pixels → opaque tint, dark pixels → transparent
    /// (background shows through). No thresholds, no pixel manipulation.
    @ViewBuilder
    private var tintedFallback: some View {
        let tint = hashColor(from: project.packageCachePath)
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.15))
            if let hatNSImage {
                tint
                    .mask {
                        Image(nsImage: hatNSImage)
                            .resizable()
                            .scaledToFit()
                            .luminanceToAlpha()
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func hashColor(from hash: String) -> Color {
        let bytes = hash.utf8.prefix(8)
        let value = bytes.reduce(0) { ($0 &<< 5) &+ Int($1) }
        let hue = Double(abs(value) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.70)
    }
}

// MARK: - Project display path

extension Project {
    var displayPath: String? {
        guard let path = originalPackagePath else { return nil }
        if path.contains(Bundle.main.bundlePath) { return nil }
        if path.hasPrefix(StorageManager.packageCacheDir.path) { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
