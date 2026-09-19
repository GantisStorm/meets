import AppKit
import MeetsCore
import SwiftUI
import UniformTypeIdentifiers

struct InsightsShareSheet: View {
    let snapshot: InsightsSnapshot
    let rangeLabel: String

    @Environment(\.dismiss) private var dismiss
    @State private var image: NSImage?
    @State private var confirmation: String?
    @State private var saveErrorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Share your activity")
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.4)
                    Text("A private snapshot with no transcripts or account details")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(1200 / 630, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.22), radius: 24, y: 12)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.quaternary)
                        .aspectRatio(1200 / 630, contentMode: .fit)
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
            .accessibilityLabel("Preview of your Meets activity image")

            if let saveErrorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The image couldn’t be saved")
                            .font(.system(size: 12, weight: .semibold))
                        Text(saveErrorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button {
                        self.saveErrorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss save error")
                }
                .padding(10)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.red.opacity(0.18)))
            }

            HStack(spacing: 10) {
                Button {
                    copyImage()
                } label: {
                    Label("Copy Image", systemImage: "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])

                Button {
                    saveImage()
                } label: {
                    Label("Save PNG", systemImage: "arrow.down.to.line")
                }

                Button {
                    shareImage()
                } label: {
                    Label("Share…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }
            .disabled(image == nil)
        }
        .padding(24)
        .frame(minWidth: 760, idealWidth: 880, minHeight: 530)
        .background(.regularMaterial)
        .task {
            image = InsightsShareRenderer.render(snapshot: snapshot, rangeLabel: rangeLabel)
        }
    }

    private func copyImage() {
        guard let image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showConfirmation("Copied")
    }

    private func saveImage() {
        guard let image, let png = InsightsShareRenderer.pngData(for: image) else { return }
        saveErrorMessage = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Meets activity – \(rangeLabel).png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let result = await Task.detached(priority: .utility) {
                    InsightsShareFileWriter.write(png, to: url)
                }.value
                switch result {
                case .saved:
                    saveErrorMessage = nil
                    showConfirmation("Saved")
                case .failed(let message):
                    saveErrorMessage = message
                }
            }
        }
    }

    private func shareImage() {
        guard let image else { return }
        InsightsNativeSharePicker.show(image: image)
    }

    private func showConfirmation(_ message: String) {
        withAnimation(.easeOut(duration: 0.16)) { confirmation = message }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard confirmation == message else { return }
            withAnimation(.easeOut(duration: 0.16)) { confirmation = nil }
        }
    }
}

enum InsightsShareSaveResult: Equatable, Sendable {
    case saved
    case failed(String)
}

enum InsightsShareFileWriter {
    static func write(_ png: Data, to url: URL) -> InsightsShareSaveResult {
        do {
            try png.write(to: url, options: .atomic)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

@MainActor
enum InsightsShareRenderer {
    static let size = CGSize(width: 1200, height: 630)

    static func render(snapshot: InsightsSnapshot, rangeLabel: String) -> NSImage? {
        AppFonts.registerForRenderingIfNeeded()
        let renderer = ImageRenderer(
            content: InsightsShareCard(snapshot: snapshot, rangeLabel: rangeLabel, showsNumbers: true)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.nsImage
    }

    static func renderTemplate() -> NSImage? {
        AppFonts.registerForRenderingIfNeeded()
        let emptyTotals = InsightsTotals(meetingWords: 0, meetings: 0, averageWPM: 0)
        let snapshot = InsightsSnapshot(
            range: .twelveMonths,
            generatedAt: Date(),
            lifetime: emptyTotals,
            selected: emptyTotals,
            dailyActivity: [],
            currentStreakDays: 0,
            longestStreakDays: 0,
            activeDaysInRange: 0,
            meetingWords: []
        )
        let renderer = ImageRenderer(
            content: InsightsShareCard(snapshot: snapshot, rangeLabel: "YOUR RANGE", showsNumbers: false)
                .frame(width: size.width, height: size.height)
        )
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.nsImage
    }

    static func pngData(for image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else { return nil }
        return representation.representation(using: .png, properties: [.compressionFactor: 0.82])
    }
}

private struct InsightsShareCard: View {
    let snapshot: InsightsSnapshot
    let rangeLabel: String
    let showsNumbers: Bool

    private struct ShareMetric {
        let label: String
        let value: String
    }

    private let pale = Color(red: 0.91, green: 0.95, blue: 0.98)
    private let muted = Color(red: 0.70, green: 0.77, blue: 0.82)
    private let cyan = Color(red: 0.20, green: 0.78, blue: 0.91)
    private let ink = Color(red: 0.025, green: 0.043, blue: 0.060)

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.071, blue: 0.090)

            if let background = InsightsBrandAssets.shareBackground {
                Image(nsImage: background)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 1200, height: 630)
                    .clipped()
            }

            LinearGradient(
                colors: [
                    ink.opacity(0.92),
                    ink.opacity(0.66),
                    ink.opacity(0.18),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                colors: [.clear, ink.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Meeting snapshot")
                            .font(.system(size: 22, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(pale)
                        Text(rangeLabel.uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1.8)
                            .foregroundStyle(muted)
                    }
                    Spacer()
                    MeetsShareMark(color: pale)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(ink.opacity(0.52))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12)))
                }

                Spacer(minLength: 24)

                HStack(alignment: .bottom, spacing: 30) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(display(formatShare(snapshot.meetingStats.totalMeetings)))
                            .font(.system(size: 82, weight: .bold, design: .rounded))
                            .tracking(-3.2)
                            .monospacedDigit()
                            .foregroundStyle(pale)
                        Text("meetings")
                            .font(.system(size: 25, weight: .semibold))
                            .tracking(-0.4)
                            .foregroundStyle(muted)
                    }

                    Spacer()

                    HStack(spacing: 32) {
                        heroFact(display(duration(snapshot.meetingStats.totalDurationSeconds)), "recorded")
                        heroFact(display(formatShare(snapshot.activeDaysInRange)), "active days")
                        heroFact(display(dayCount(snapshot.currentStreakDays)), "current streak")
                    }
                }

                Spacer(minLength: 26)

                HStack(alignment: .top, spacing: 0) {
                    shareGroup("Capture", metrics: captureMetrics)
                    shareDivider
                    shareGroup("Workflow", metrics: workflowMetrics)
                    shareDivider
                    shareGroup("AI", metrics: aiMetrics)
                    shareDivider
                    shareGroup("Calendar", metrics: calendarMetrics)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .background(ink.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Spacer(minLength: 20)

                HStack {
                    Text("Private by design · Computed on this Mac · No transcripts shared")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(pale.opacity(0.90))
                        .shadow(color: Color.black.opacity(0.48), radius: 3, y: 1)
                    Spacer()
                    MeetsWordmark(size: 15, color: cyan, periodColor: Color(red: 0.90, green: 0.28, blue: 0.30))
                        .shadow(color: Color.black.opacity(0.48), radius: 3, y: 1)
                    }
            }
            .padding(46)
        }
    }

    private var captureMetrics: [ShareMetric] {
        let stats = snapshot.meetingStats
        return [
            ShareMetric(label: "Recorded time", value: display(duration(stats.totalDurationSeconds))),
            ShareMetric(label: "Words captured", value: display(formatShare(stats.totalWords))),
            ShareMetric(label: "Average length", value: display(duration(stats.averageDurationSeconds))),
            ShareMetric(label: "With audio", value: display(sharePercent(stats.meetingsWithRecording, of: stats.totalMeetings))),
            ShareMetric(label: "Audio imports", value: display(formatShare(stats.importedMeetings))),
        ]
    }

    private var workflowMetrics: [ShareMetric] {
        let stats = snapshot.meetingStats
        return [
            ShareMetric(label: "Completed", value: display(formatShare(stats.completedMeetings))),
            ShareMetric(label: "Failed", value: display(formatShare(stats.failedMeetings))),
            ShareMetric(label: "Follow-ups", value: display(formatShare(stats.followUpMeetings))),
            ShareMetric(label: "Active days", value: display(formatShare(snapshot.activeDaysInRange))),
            ShareMetric(label: "Best streak", value: display(dayCount(snapshot.longestStreakDays))),
        ]
    }

    private var aiMetrics: [ShareMetric] {
        let stats = snapshot.llmStats
        return [
            ShareMetric(label: "Runs", value: display(formatShare(stats.totalRuns))),
            ShareMetric(label: "Successful", value: display(sharePercent(stats.successfulRuns, of: stats.totalRuns))),
            ShareMetric(label: "Summaries", value: display(formatShare(kindCount("summary")))),
            ShareMetric(label: "Cleanups", value: display(formatShare(kindCount("cleanup")))),
            ShareMetric(label: "Characters", value: display(formatShare(stats.totalCharacters))),
        ]
    }

    private var calendarMetrics: [ShareMetric] {
        let stats = snapshot.calendarStats
        return [
            ShareMetric(label: "Events", value: display(formatShare(stats.eventsInRange))),
            ShareMetric(label: "Meetings linked", value: display(sharePercent(snapshot.meetingStats.meetingsLinkedToCalendar, of: snapshot.meetingStats.totalMeetings))),
            ShareMetric(label: "Recorded", value: display(formatShare(stats.recordedEvents))),
            ShareMetric(label: "Missed", value: display(formatShare(stats.missedEvents))),
            ShareMetric(label: "Upcoming", value: display(formatShare(stats.upcomingEvents))),
        ]
    }

    private func display(_ value: String) -> String {
        showsNumbers ? value : "—"
    }

    private func duration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = Int(seconds) % 3600 / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func dayCount(_ days: Int) -> String {
        "\(days)d"
    }

    private func sharePercent(_ part: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((Double(part) / Double(total) * 100).rounded()))%"
    }

    private func formatShare(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    private func kindCount(_ kind: String) -> Int {
        snapshot.llmStats.byKind.reduce(into: 0) { result, entry in
            if entry.key.lowercased() == kind { result += entry.value }
        }
    }

    private func heroFact(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .tracking(-0.5)
                .monospacedDigit()
                .foregroundStyle(pale)
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(1.3)
                .foregroundStyle(muted)
        }
    }

    private func shareGroup(_ title: String, metrics: [ShareMetric]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(cyan)
                .padding(.bottom, 2)

            ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(metric.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Spacer(minLength: 4)
                    Text(metric.value)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(pale)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private var shareDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 148)
    }
}

private struct MeetsShareMark: View {
    let color: Color

    var body: some View {
        MeetsWordmark(size: 30, color: color, periodColor: Color(red: 0.90, green: 0.28, blue: 0.30))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Meets")
    }
}

enum InsightsBrandAssets {
    static let shareBackground = image(
        bundledName: "insights-share-background",
        extension: "png",
        repositoryPath: "assets/insights-share-background.png"
    )
    static let appIcon: NSImage? = nil

    private static func image(bundledName: String, extension fileExtension: String, repositoryPath: String) -> NSImage? {
        if let bundledURL = Bundle.main.url(forResource: bundledName, withExtension: fileExtension),
           let image = NSImage(contentsOf: bundledURL) {
            return image
        }
        if let repositoryRoot = ProcessInfo.processInfo.environment["MEETS_REPO_ROOT"],
           let image = NSImage(contentsOf: URL(fileURLWithPath: repositoryRoot, isDirectory: true).appendingPathComponent(repositoryPath)) {
            return image
        }
        let workingDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        if let image = NSImage(contentsOf: workingDirectoryURL.appendingPathComponent(repositoryPath)) {
            return image
        }
        guard let runtime = try? RuntimePaths.resolve() else { return nil }
        return NSImage(contentsOf: runtime.repoRoot.appendingPathComponent(repositoryPath))
    }
}

@MainActor
private enum InsightsNativeSharePicker {
    private static var picker: NSSharingServicePicker?

    static func show(image: NSImage) {
        guard let sourceView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [image])
        self.picker = picker
        let anchor = NSRect(x: sourceView.bounds.midX, y: sourceView.bounds.midY, width: 1, height: 1)
        picker.show(relativeTo: anchor, of: sourceView, preferredEdge: .minY)
    }
}
