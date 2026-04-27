import SwiftUI

/// Lightweight card container used across the configuration and runtime
/// columns. Material + thin stroke; the heavier drop shadow was dropped on
/// purpose – stacking 5+ shadowed cards on a window-sized gradient looked busy
/// without adding information.
struct GlassCard<Content: View>: View {
    let title: String
    let systemImage: String?
    @ViewBuilder let content: Content

    init(title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        }
    }
}
