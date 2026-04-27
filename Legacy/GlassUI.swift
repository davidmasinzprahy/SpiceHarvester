import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Systém"
        case .light: return "Den"
        case .dark: return "Noc"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct AppearanceModeOptionButton: View {
    let mode: AppearanceMode
    let isSelected: Bool
    let palette: GlassPalette
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(mode.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
            }
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundShape)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var foregroundColor: Color {
        if isSelected {
            return palette.textPrimary
        }

        return isHovered ? palette.textPrimary : palette.textSecondary
    }

    private var backgroundShape: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(backgroundFill)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 1.2 : 1)
            )
    }

    private var backgroundFill: Color {
        if isSelected {
            return palette.accent.opacity(0.22)
        }

        return isHovered ? Color.white.opacity(0.16) : Color.white.opacity(0.08)
    }

    private var borderColor: Color {
        if isSelected {
            return palette.accent.opacity(0.75)
        }

        return isHovered ? palette.border.opacity(1.0) : palette.border
    }
}

struct HelpIconButton: View {
    let palette: GlassPalette
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "questionmark")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(isHovered ? palette.textPrimary : palette.textSecondary)
                .frame(width: 34, height: 34)
                .background(backgroundShape)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel("Nápověda")
        .help("Nápověda")
    }

    private var backgroundShape: some View {
        Circle()
            .fill(isHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
            .overlay(
                Circle()
                    .stroke(isHovered ? palette.border.opacity(1) : palette.border.opacity(0.82), lineWidth: 1)
            )
            .shadow(color: palette.shadow.opacity(isHovered ? 0.75 : 0.45), radius: isHovered ? 12 : 8, x: 0, y: 4)
    }
}

struct GlassAppIcon: View {
    let palette: GlassPalette
    var imageName: String = "AppLogo"
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.24),
                                    palette.accent.opacity(0.22),
                                    palette.secondaryAccent.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.58), palette.border.opacity(0.92)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.1
                        )
                )
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(Color.white.opacity(0.26))
                        .frame(width: size * 0.34, height: size * 0.34)
                        .blur(radius: 10)
                        .offset(x: size * 0.08, y: size * 0.05)
                }
                .shadow(color: palette.shadow.opacity(0.32), radius: 16, x: 0, y: 10)

            Image(imageName)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.56, height: size * 0.56)
        }
        .frame(width: size, height: size)
    }
}

struct GlassIconGlyph: View {
    let systemName: String
    let palette: GlassPalette
    var isHighlighted: Bool = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(isHighlighted ? palette.textPrimary : palette.textSecondary)
            .frame(width: 34, height: 34)
            .background(backgroundShape)
            .contentShape(Circle())
    }

    private var backgroundShape: some View {
        Circle()
            .fill(.ultraThinMaterial)
            .overlay(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHighlighted ? 0.26 : 0.14),
                                palette.accent.opacity(isHighlighted ? 0.16 : 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                Circle()
                    .stroke(isHighlighted ? palette.border.opacity(1) : palette.border.opacity(0.82), lineWidth: 1)
            )
            .shadow(color: palette.shadow.opacity(isHighlighted ? 0.75 : 0.45), radius: isHighlighted ? 12 : 8, x: 0, y: 4)
    }
}

struct GlassIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let palette: GlassPalette
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            GlassIconGlyph(systemName: systemName, palette: palette, isHighlighted: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }
}

struct GlassPalette {
    let topGlow: Color
    let bottomGlow: Color
    let accent: Color
    let secondaryAccent: Color
    let border: Color
    let shadow: Color
    let textPrimary: Color
    let textSecondary: Color

    static func forScheme(_ scheme: ColorScheme) -> GlassPalette {
        switch scheme {
        case .dark:
            return GlassPalette(
                topGlow: Color(red: 0.10, green: 0.16, blue: 0.26),
                bottomGlow: Color(red: 0.05, green: 0.07, blue: 0.11),
                accent: Color(red: 0.42, green: 0.78, blue: 0.86),
                secondaryAccent: Color(red: 0.44, green: 0.52, blue: 0.96),
                border: Color.white.opacity(0.20),
                shadow: Color.black.opacity(0.35),
                textPrimary: Color.white.opacity(0.95),
                textSecondary: Color.white.opacity(0.68)
            )
        default:
            return GlassPalette(
                topGlow: Color(red: 0.93, green: 0.96, blue: 1.00),
                bottomGlow: Color(red: 0.82, green: 0.89, blue: 0.98),
                accent: Color(red: 0.11, green: 0.49, blue: 0.76),
                secondaryAccent: Color(red: 0.20, green: 0.66, blue: 0.57),
                border: Color.white.opacity(0.55),
                shadow: Color.black.opacity(0.12),
                textPrimary: Color.black.opacity(0.82),
                textSecondary: Color.black.opacity(0.55)
            )
        }
    }
}

struct GlassBackground: View {
    let palette: GlassPalette

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.topGlow, palette.bottomGlow],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(palette.accent.opacity(0.26))
                .frame(width: 360, height: 360)
                .blur(radius: 24)
                .offset(x: -200, y: -180)

            Circle()
                .fill(palette.secondaryAccent.opacity(0.22))
                .frame(width: 300, height: 300)
                .blur(radius: 20)
                .offset(x: 240, y: 210)

            RoundedRectangle(cornerRadius: 120, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 420, height: 420)
                .blur(radius: 20)
                .offset(x: 160, y: -260)
        }
        .ignoresSafeArea()
    }
}

struct GlassCardModifier: ViewModifier {
    let palette: GlassPalette
    var cornerRadius: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [palette.border, Color.white.opacity(0.06)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: palette.shadow, radius: 20, x: 0, y: 12)
    }
}

extension View {
    func glassCard(palette: GlassPalette, cornerRadius: CGFloat = 28) -> some View {
        modifier(GlassCardModifier(palette: palette, cornerRadius: cornerRadius))
    }
}

struct GlassSection<Content: View>: View {
    let title: String
    let subtitle: String?
    let palette: GlassPalette
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.textPrimary)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(palette.textSecondary)
                }
            }

            content
        }
        .padding(22)
        .glassCard(palette: palette)
    }
}
