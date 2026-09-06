import AppKit
import SwiftUI

/// The Meets brand wordmark: "Meets" in a stylized cursive face with a red
/// period. Used everywhere a logo would appear (sidebar, onboarding, share).
struct MeetsWordmark: View {
    /// Point size of the wordmark text.
    var size: CGFloat = 26
    var color: Color = .primary
    /// Period color. Defaults to the theme's recording red when running in
    /// the app; callers may override (e.g. share-card light surfaces).
    var periodColor: Color?

    private var resolvedPeriodColor: Color {
        periodColor ?? MeetsTheme.recording
    }

    /// Cursive face: Snell Roundhand ships with macOS (Supplemental fonts).
    /// Weight names: Regular, Bold, Black.
    private var cursiveFont: NSFont {
        NSFont(name: "SnellRoundhand-Bold", size: size)
            ?? NSFont(name: "SnellRoundhand", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: .bold)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Meets")
                .font(Font(cursiveFont))
                .foregroundStyle(color)
            Text(".")
                .font(Font(cursiveFont))
                .foregroundStyle(resolvedPeriodColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Meets")
        .fixedSize()
    }
}
