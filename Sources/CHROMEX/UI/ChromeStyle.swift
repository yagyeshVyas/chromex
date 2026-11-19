import SwiftUI
import UIKit

/// Chrome's own colour language, so the browser chrome reads like desktop Chrome
/// instead of borrowing the app's violet brand surface. Hub, Settings and the
/// privacy pages keep `ChromexColor`; everything framing a web page uses this.
enum ChromeStyle {
    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        ChromexColor.dynamic(dark: dark, light: light)
    }

    // Surfaces
    static let page = dynamic(dark: 0x202124, light: 0xFFFFFF)
    static let tabStrip = dynamic(dark: 0x292A2D, light: 0xDEE1E6)
    static let tabActive = dynamic(dark: 0x35363A, light: 0xFFFFFF)
    static let tabInactive = dynamic(dark: 0x202124, light: 0xDADCE0)
    static let toolbar = dynamic(dark: 0x35363A, light: 0xFFFFFF)
    static let toolbarRaised = dynamic(dark: 0x292A2D, light: 0xFFFFFF)
    static let omnibox = dynamic(dark: 0x202124, light: 0xF1F3F4)
    static let omniboxFocused = dynamic(dark: 0x292A2D, light: 0xFFFFFF)
    static let separator = dynamic(dark: 0x3C4043, light: 0xDADCE0)

    // Text
    static let text = dynamic(dark: 0xE8EAED, light: 0x202124)
    static let textSecondary = dynamic(dark: 0x9AA0A6, light: 0x5F6368)
    static let textTertiary = dynamic(dark: 0x5F6368, light: 0x80868B)
    static let tabTextInactive = dynamic(dark: 0x9AA0A6, light: 0x3C4043)

    // Accent
    static let accent = dynamic(dark: 0x8AB4F8, light: 0x1A73E8)
    static let danger = dynamic(dark: 0xF28B82, light: 0xD93025)
    static let incognito = dynamic(dark: 0xC58AF9, light: 0x5F1FA8)

    static let tabStripHeight: CGFloat = 36
    static let toolbarHeight: CGFloat = 54
    static let bookmarksHeight: CGFloat = 32
    static let findBarHeight: CGFloat = 44

    static func chromeHeight(bookmarksVisible: Bool) -> CGFloat {
        tabStripHeight + toolbarHeight + (bookmarksVisible ? bookmarksHeight : 0)
    }
}

// MARK: - Small chrome pieces

struct ChromeIconButton: View {
    let symbol: String
    var size: CGFloat = 17
    var enabled: Bool = true
    var tint: Color = ChromeStyle.text
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(enabled ? tint : ChromeStyle.textTertiary.opacity(0.5))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A circle with the first letter of a site. No favicon service exists on iOS
/// without per-tile network work, so the letter is honest and instant.
struct SiteLetterMark: View {
    let text: String
    var size: CGFloat = 32
    var tint: Color = ChromeStyle.accent

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.14))
            Text(String(text.prefix(1)).uppercased())
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

struct ChromeDivider: View {
    var body: some View {
        Rectangle()
            .fill(ChromeStyle.separator)
            .frame(height: 0.5)
    }
}
