import SwiftUI
import MeetsCore

struct AboutView: View {
    let appState: AppState
    private let actionButtonWidth: CGFloat = 136

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        return "v\(v)"
    }

    private var appDataPath: String {
        AppIdentity.supportDirectoryURL.path
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MeetsTheme.spacing32) {
                Text("About")
                    .font(MeetsTheme.title1())
                    .foregroundStyle(MeetsTheme.textPrimary)

                if let banner = updateBanner {
                    updateBannerView(banner)
                }

                // MARK: - App Info
                sectionHeader("App Info")
                aboutCard {
                    aboutRow("Version") {
                        Text(version)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(MeetsTheme.textPrimary)
                    }

                    Divider().background(MeetsTheme.surfaceBorder)

                    aboutRow("Updates") {
                        Text(updateRowGuidance)
                            .font(MeetsTheme.callout())
                            .foregroundStyle(MeetsTheme.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                }

                // MARK: - Data
                sectionHeader("Data")
                aboutCard {
                    VStack(alignment: .leading, spacing: MeetsTheme.spacing12) {
                        Text("App Data Directory")
                            .font(MeetsTheme.body())
                            .foregroundStyle(MeetsTheme.textPrimary)

                        HStack {
                            Text(appDataPath)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(MeetsTheme.textTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            actionButton("Open", icon: "folder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: appDataPath)
                            }
                        }
                    }
                }

                // MARK: - Acknowledgements
                sectionHeader("Acknowledgements")
                aboutCard {
                    acknowledgement(
                        name: "Muesli by Muesli-HQ",
                        description: "Meets is a meetings-only fork of Muesli (github.com/Muesli-HQ/muesli), \u{00A9} 2026 Pranav Hari, available under the MIT License."
                    )

                    Divider().background(MeetsTheme.surfaceBorder)

                    acknowledgement(
                        name: "FluidAudio by FluidInference",
                        description: "CoreML speech stack powering Parakeet, Qwen3 ASR, Silero VAD, and speaker diarization on Apple Silicon."
                    )
                    Divider().background(MeetsTheme.surfaceBorder)
                    acknowledgement(
                        name: "LocalVQE by localai-org",
                        description: "On-device acoustic echo cancellation powering cleaner meeting transcription."
                    )
                    Divider().background(MeetsTheme.surfaceBorder)
                    acknowledgement(
                        name: "WhisperKit by Argmax",
                        description: "Swift Whisper inference on CoreML/ANE powering the app's Whisper Small, Medium, and Large Turbo backends."
                    )
                }

                Spacer(minLength: MeetsTheme.spacing32)
            }
            .padding(.horizontal, MeetsTheme.spacing32)
            .padding(.top, MeetsTheme.pageTop)
            .padding(.bottom, MeetsTheme.spacing32)
        }
        .background(MeetsTheme.backgroundBase)
    }

    // MARK: - Components

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(MeetsTheme.textTertiary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }

    @ViewBuilder
    private func aboutCard(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(MeetsTheme.spacing20)
        .background(MeetsTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private struct UpdateBanner {
        let icon: String
        let title: String
        let message: String
        let tint: Color
    }

    private var updateRowGuidance: String {
        switch appState.sparkleUpdateStatus {
        case .available:
            return "Use the menu bar icon > Check for Updates..."
        case .downloaded:
            return "Use the menu bar updater to finish installation."
        case .checking, .busy, .installing:
            return "Checking..."
        case .failed:
            return "Use the menu bar icon > Check for Updates..."
        case .idle, .upToDate, .disabled:
            return "Use the menu bar icon > Check for Updates..."
        }
    }

    private var updateBanner: UpdateBanner? {
        switch appState.sparkleUpdateStatus {
        case .idle:
            return nil
        case .checking:
            return UpdateBanner(
                icon: "arrow.triangle.2.circlepath",
                title: "Checking for updates",
                message: "Meets is checking the appcast for the latest version.",
                tint: MeetsTheme.transcribing
            )
        case .busy(let message):
            return UpdateBanner(
                icon: "clock.arrow.circlepath",
                title: "Updater is busy",
                message: message,
                tint: MeetsTheme.transcribing
            )
        case .available(let version):
            return UpdateBanner(
                icon: "exclamationmark.triangle.fill",
                title: "Meets \(version) is available",
                message: "An update is available. Use the menu bar icon > Check for Updates... to open the updater.",
                tint: MeetsTheme.transcribing
            )
        case .downloaded(let version):
            return UpdateBanner(
                icon: "exclamationmark.triangle.fill",
                title: "Meets \(version) is ready to install",
                message: "The update is downloaded. Use the menu bar updater to finish installation.",
                tint: MeetsTheme.transcribing
            )
        case .installing(let version):
            return UpdateBanner(
                icon: "arrow.down.circle.fill",
                title: "Installing Meets \(version)",
                message: "Sparkle is preparing the update. Meets may relaunch when installation finishes.",
                tint: MeetsTheme.transcribing
            )
        case .upToDate:
            return UpdateBanner(
                icon: "checkmark.circle.fill",
                title: "Meets is up to date",
                message: "No newer version was found in the appcast.",
                tint: MeetsTheme.success
            )
        case .disabled(let message):
            return UpdateBanner(
                icon: "minus.circle.fill",
                title: "Updates are disabled",
                message: message,
                tint: MeetsTheme.textTertiary
            )
        case .failed(let message):
            return UpdateBanner(
                icon: "xmark.octagon.fill",
                title: "Update check failed",
                message: "\(message) Use the menu bar icon > Check for Updates... to try again.",
                tint: MeetsTheme.recording
            )
        }
    }

    @ViewBuilder
    private func updateBannerView(_ banner: UpdateBanner) -> some View {
        HStack(alignment: .top, spacing: MeetsTheme.spacing12) {
            Image(systemName: banner.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(banner.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                Text(banner.title)
                    .font(MeetsTheme.headline())
                    .foregroundStyle(MeetsTheme.textPrimary)
                Text(banner.message)
                    .font(MeetsTheme.callout())
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: MeetsTheme.spacing16)
        }
        .padding(MeetsTheme.spacing16)
        .background(banner.tint.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MeetsTheme.cornerMedium)
                .strokeBorder(banner.tint.opacity(0.45), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func aboutRow(_ label: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(MeetsTheme.body())
                .foregroundStyle(MeetsTheme.textPrimary)
            Spacer()
            control()
        }
        .padding(.vertical, MeetsTheme.spacing8)
    }

    @ViewBuilder
    private func acknowledgement(name: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
            Text(name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MeetsTheme.textPrimary)
            Text(description)
                .font(MeetsTheme.callout())
                .foregroundStyle(MeetsTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, MeetsTheme.spacing8)
    }

    @ViewBuilder
    private func actionButton(_ title: String, icon: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(MeetsTheme.textPrimary)
            .padding(.horizontal, MeetsTheme.spacing16)
            .padding(.vertical, MeetsTheme.spacing8)
            .frame(width: actionButtonWidth)
            .background(MeetsTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .strokeBorder(MeetsTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
