import SwiftUI

/// Displays a trust status badge with appropriate icon and color.
struct TrustBadge: View {
    let status: TrustStatus

    var body: some View {
        Label(label, systemImage: icon)
            .foregroundStyle(color)
            .font(.subheadline.weight(.medium))
    }

    private var icon: String {
        switch status {
        case .verified:      "checkmark.seal.fill"
        case .trustedByUser: "person.badge.shield.checkmark.fill"
        case .newPublisher:  "questionmark.circle.fill"
        case .unsigned:      "exclamationmark.triangle.fill"
        case .tampered:      "xmark.seal.fill"
        }
    }

    private var color: Color {
        switch status {
        case .verified:      .green
        case .trustedByUser: .blue
        case .newPublisher:  .orange
        case .unsigned:      .yellow
        case .tampered:      .red
        }
    }

    private var label: String {
        switch status {
        case .verified:      "Verified"
        case .trustedByUser: "Trusted"
        case .newPublisher:  "New Publisher"
        case .unsigned:      "Unsigned"
        case .tampered:      "Tampered"
        }
    }
}
