import SwiftUI

struct MeetingPreparationBanner: View {
    let status: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: MeetsTheme.spacing12) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 18, height: 18)
                .accessibilityLabel("Preparing transcription")

            VStack(alignment: .leading, spacing: 2) {
                Text("Preparing transcription")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MeetsTheme.textPrimary)
                Text(status ?? "Meeting transcription will start shortly.")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: MeetsTheme.spacing12)

            Button(action: onCancel) {
                Label("Cancel", systemImage: "xmark.circle")
                    .font(MeetsTheme.caption())
                    .foregroundStyle(MeetsTheme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Cancel meeting preparation")
        }
        .padding(MeetsTheme.spacing12)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerLarge)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }
}
