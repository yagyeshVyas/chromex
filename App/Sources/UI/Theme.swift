import SwiftUI
import UIKit

// MARK: - Colour

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

enum ChromexColor {
    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }

    static let background = dynamic(dark: 0x05070B, light: 0xF5F6FA)
    static let surface = dynamic(dark: 0x10141D, light: 0xFFFFFF)
    static let surfaceRaised = dynamic(dark: 0x151A24, light: 0xEDEFF6)
    static let surfaceSunken = dynamic(dark: 0x0A0D14, light: 0xE6E9F1)
    static let textPrimary = dynamic(dark: 0xE4E9F2, light: 0x11151F)
    static let textSecondary = dynamic(dark: 0x96A0B8, light: 0x555F75)
    static let textTertiary = dynamic(dark: 0x6B7690, light: 0x8A93A6)
    static let hairline = dynamic(dark: 0x252C3D, light: 0xD9DEE8)

    static let electricBlue = Color(hex: 0x2E6BFF)
    static let electricBlueBright = Color(hex: 0x4D8BFF)
    static let violet = Color(hex: 0x8B5CF6)
    static let success = Color(hex: 0x34D399)
    static let warning = Color(hex: 0xFBBF24)
    static let danger = Color(hex: 0xF87171)

    static let accentGradient = LinearGradient(
        colors: [Color(hex: 0x2E6BFF), Color(hex: 0x8B5CF6)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let homeGlow = RadialGradient(
        colors: [Color(hex: 0x2E6BFF).opacity(0.28), Color.clear],
        center: .top,
        startRadius: 10,
        endRadius: 420
    )
}

// MARK: - Type

enum ChromexFont {
    static func display(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .bold, design: .default) }
    static let title = Font.system(size: 24, weight: .bold)
    static let headline = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 16, weight: .regular)
    static let callout = Font.system(size: 15, weight: .regular)
    static let footnote = Font.system(size: 13, weight: .regular)
    static let caption = Font.system(size: 11, weight: .medium)
    static let mono = Font.system(size: 12, weight: .regular, design: .monospaced)
}

// MARK: - Surfaces

struct SurfaceCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ChromexColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(ChromexColor.hairline, lineWidth: 0.5)
            )
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(ChromexFont.caption)
                .tracking(0.8)
                .foregroundStyle(ChromexColor.textTertiary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(ChromexFont.caption)
                    .foregroundStyle(ChromexColor.textTertiary)
            }
        }
    }
}

struct StateDot: View {
    enum Kind { case active, idle, fault, blocked }
    let kind: Kind

    var color: Color {
        switch kind {
        case .active: return ChromexColor.success
        case .idle: return ChromexColor.textTertiary
        case .fault: return ChromexColor.warning
        case .blocked: return ChromexColor.danger
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(ChromexColor.textTertiary)
            Text(title)
                .font(ChromexFont.headline)
                .foregroundStyle(ChromexColor.textPrimary)
            Text(message)
                .font(ChromexFont.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(ChromexColor.textSecondary)
                .frame(maxWidth: 280)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 4)
            }
        }
        .padding(28)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = ChromexColor.electricBlue

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ChromexFont.headline)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(fill.opacity(configuration.isPressed ? 0.82 : 1), in: Capsule())
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ChromexFont.callout)
            .foregroundStyle(ChromexColor.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                ChromexColor.surfaceRaised.opacity(configuration.isPressed ? 0.7 : 1),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
    }
}

// MARK: - Verdict

struct VerdictBadge: View {
    let verdict: CompatibilityVerdict

    private var tint: Color {
        switch verdict {
        case .runs: return ChromexColor.success
        case .runsWithLimits: return ChromexColor.warning
        case .unsupported: return ChromexColor.textSecondary
        case .refused: return ChromexColor.danger
        }
    }

    private var symbol: String {
        switch verdict {
        case .runs: return "checkmark.seal.fill"
        case .runsWithLimits: return "exclamationmark.triangle.fill"
        case .unsupported: return "xmark.circle"
        case .refused: return "hand.raised.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
            Text(verdict.title)
                .font(ChromexFont.headline)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Background

struct BrowserBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            ChromexColor.background
            if scheme == .dark {
                ChromexColor.homeGlow.opacity(0.55)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Utilities

extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(ChromexColor.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(ChromexColor.hairline, lineWidth: 0.5)
            )
    }

    func screen() -> some View {
        self.background(BrowserBackground())
    }
}
