import SwiftUI

/// Main library view showing all imported projects.
struct LibraryView: View {
    @Bindable var store: ProjectStore
    @Binding var selectedProject: Project?

    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 16)
    ]

    var body: some View {
        Group {
            if store.projects.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(store.projects) { project in
                            ProjectCard(project: project)
                                .onTapGesture {
                                    selectedProject = project
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Library")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No Projects")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Open a .vibeapp to get started")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Card view for a single project in the library grid.
private struct ProjectCard: View {
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "app.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Spacer()
                if project.isEncrypted {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.purple)
                        .font(.caption)
                }
                TrustBadge(status: project.trustStatus)
            }

            Text(project.appName)
                .font(.headline)
                .lineLimit(1)

            Text("v\(project.appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let publisher = project.publisher {
                Text(publisher)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Text(project.importedAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}
