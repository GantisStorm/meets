import SwiftUI

struct DiagnosticIncidentReportView: View {
    let incident: DiagnosticIncident
    let onOpenIssue: () -> Void
    let onDismiss: () -> Void

    private var isManualReport: Bool {
        incident.kind == .manualReport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MeetsTheme.spacing20) {
            HStack(alignment: .top, spacing: MeetsTheme.spacing12) {
                Image(systemName: isManualReport ? "exclamationmark.bubble.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isManualReport ? MeetsTheme.accent : .orange)
                VStack(alignment: .leading, spacing: MeetsTheme.spacing4) {
                    Text(isManualReport ? "Report a Problem" : "Diagnostic Failure Detected")
                        .font(MeetsTheme.title3())
                        .foregroundStyle(MeetsTheme.textPrimary)
                    Text(isManualReport ? "\(AppIdentity.displayName) can prepare an anonymized GitHub issue for you to review before opening it." : "\(AppIdentity.displayName) detected a hard failure in \(incident.stage.rawValue). You can review the anonymized report before opening a GitHub issue.")
                        .font(MeetsTheme.callout())
                        .foregroundStyle(MeetsTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !isManualReport {
                VStack(alignment: .leading, spacing: MeetsTheme.spacing8) {
                    diagnosticSummaryRow("Failure", value: incident.kind.title)
                    diagnosticSummaryRow("Stage", value: incident.stage.rawValue)
                    diagnosticSummaryRow("Model", value: incident.model)
                    diagnosticSummaryRow("Error", value: incident.errorDisplayIdentifier)
                    diagnosticSummaryRow("Meaning", value: incident.errorFingerprint.summary)
                }
                .padding(MeetsTheme.spacing12)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                        .stroke(Color.orange.opacity(0.24), lineWidth: 1)
                )
            }

            Text("Only allowlisted diagnostic categories and a random incident ID are included. No transcript, audio, meeting title, calendar title, clipboard contents, screen text, API keys, auth tokens, local file paths, raw error messages, raw logs, or database contents are included.")
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(incident.issueBody)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(MeetsTheme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MeetsTheme.spacing12)
            }
            .frame(minHeight: 240)
            .background(MeetsTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MeetsTheme.cornerSmall)
                    .stroke(MeetsTheme.surfaceBorder, lineWidth: 1)
            )

            HStack {
                Spacer()
                Button("Not Now") {
                    onDismiss()
                }
                Button("Open GitHub Issue") {
                    onOpenIssue()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(MeetsTheme.spacing24)
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 720, minHeight: 460)
        .background(MeetsTheme.backgroundBase)
    }

    @ViewBuilder
    private func diagnosticSummaryRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: MeetsTheme.spacing12) {
            Text(label)
                .font(MeetsTheme.captionMedium())
                .foregroundStyle(MeetsTheme.textTertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(MeetsTheme.caption())
                .foregroundStyle(MeetsTheme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
