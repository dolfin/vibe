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
        case .verified: "checkmark.seal.fill"
        case .signed: "seal.fill"
        case .unsigned: "exclamationmark.triangle.fill"
        case .tampered: "xmark.seal.fill"
        }
    }

    private var color: Color {
        switch status {
        case .verified: .green
        case .signed: .blue
        case .unsigned: .yellow
        case .tampered: .red
        }
    }

    private var label: String {
        switch status {
        case .verified: "Verified"
        case .signed: "Signed"
        case .unsigned: "Unsigned"
        case .tampered: "Tampered"
        }
    }
}
