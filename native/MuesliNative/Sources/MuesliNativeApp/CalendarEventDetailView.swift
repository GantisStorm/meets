import AppKit
import SwiftUI
import MuesliCore

/// Apple-Calendar "get info"-style event panel: the command center for one
/// calendar event. Shows the event's identity (calendar, time, join link,
/// attendees, location) plus a state zone that turns the event into meeting
/// actions — record now, join & record, control a live recording, open the
/// recorded transcript, follow-ups, and folder context. Presented by
/// CalendarPageView when a day/list row is selected; Esc or the close
/// button dismisses it.
struct CalendarEventDetailView: View {
    let appState: AppState
    let controller: MuesliController
    let event: UnifiedCalendarEvent
    let onClose: () -> Void

    @State private var editableTitle: String
    @State private var pendingTitleText: String?
    @State private var isSummarizing = false
    @State private var isCleaningTranscript = false
    @State private var showCleanupConfirmation = false
    @State private var summaryErrorMessage: String?
    @State private var cleanupErrorMessage: String?
    /// Non-nil while a meeting title edit awaits the event-backed sync.
    @State private var titleSyncMeetingID: Int64?

    init(
        appState: AppState,
        controller: MuesliController,
        event: UnifiedCalendarEvent,
        onClose: @escaping () -> Void
    ) {
        self.appState = appState
        self.controller = controller
        self.event = event
        self.onClose = onClose
        _editableTitle = State(initialValue: event.title)
    }

    private var isCancelled: Bool {
        event.isCancelled || event.isDeclined
    }

    private var linkage: MeetingEventLinkage {
        MeetingEventLinkage.derive(
            event: event,
            meetings: appState.meetingRows,
            additionalLinkedMeetingIDs: controller.meetingIDsLinked(toEvent: event),
            isCurrentlyRecording: appState.isMeetingRecording || appState.isMeetingStarting
        )
    }

    private var linkedMeeting: MeetingRecord? {
        linkage.linkedMeeting
    }

    private var busy: Bool {
        appState.isMeetingRecording || appState.isMeetingStarting
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().background(MuesliTheme.surfaceBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    titleSection
                    identitySection
                    if isCancelled {
                        cancelledBanner
                    }
                    stateSection
                    if let location = trimmedLocation {
                        locationLine(location)
                    }
                    if !event.attendees.isEmpty {
                        attendeesSection
                    }
                    followUpSection
                    folderSection
                }
                .padding(.horizontal, MuesliTheme.spacing20)
                .padding(.vertical, MuesliTheme.spacing16)
            }
        }
        .frame(width: 420)
        .background(MuesliTheme.backgroundBase)
        .onAppear { editableTitle = event.title }
        .onChange(of: event.title) { _, newTitle in
            editableTitle = newTitle
            pendingTitleText = nil
        }
        .onExitCommand(perform: onClose)
        .alert("Couldn't Re-summarize", isPresented: errorBinding($summaryErrorMessage)) {
            Button("OK", role: .cancel) { summaryErrorMessage = nil }
        } message: {
            Text(summaryErrorMessage ?? "The meeting notes could not be updated.")
        }
        .alert("Cleanup Failed", isPresented: errorBinding($cleanupErrorMessage)) {
            Button("OK", role: .cancel) { cleanupErrorMessage = nil }
        } message: {
            Text(cleanupErrorMessage ?? "The transcript could not be cleaned.")
        }
        .confirmationDialog(
            "Clean up transcript?",
            isPresented: $showCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clean Up Transcript") {
                runTranscriptCleanup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Runs the transcript through the configured cleanup model to remove filler words and disfluencies. The stored transcript is replaced.")
        }
    }

    // MARK: - Chrome

    private var headerBar: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("Event")
                .font(MuesliTheme.headline())
                .foregroundStyle(MuesliTheme.textPrimary)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
            .accessibilityLabel("Close event details")
        }
        .padding(.horizontal, MuesliTheme.spacing16)
        .padding(.vertical, MuesliTheme.spacing8)
        .background(MuesliTheme.backgroundRaised)
    }

    // MARK: - Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            TextField("Meeting title", text: $editableTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(MuesliTheme.textPrimary)
                .padding(.horizontal, MuesliTheme.spacing12)
                .padding(.vertical, 8)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
                .onSubmit(commitTitleEdit)
                .onChange(of: editableTitle) { _, newValue in
                    pendingTitleText = newValue
                }
                .disabled(isCancelled && linkedMeeting == nil)
                .help(isCancelled && linkedMeeting == nil
                    ? "This event was cancelled and cannot be edited here"
                    : "Edit the event title (Return to save)")

            if let meeting = linkedMeeting, pendingTitleText != nil, pendingTitleText != event.title {
                if titleSyncMeetingID == meeting.id {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Synchronizing meeting title…")
                            .font(MuesliTheme.caption())
                            .foregroundStyle(MuesliTheme.textTertiary)
                    }
                    .padding(.vertical, 2)
                } else {
                    HStack(spacing: MuesliTheme.spacing8) {
                        Button {
                            commitTitleEdit()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                Text("Save Event Title")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(MuesliTheme.accentContent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(MuesliTheme.accent)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Save the title to the calendar event (Return)")

                        if meeting.title != pendingTitleText {
                            Button {
                                commitTitleEdit()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text("Sync Meeting Title")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(MuesliTheme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(MuesliTheme.surfacePrimary)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule().strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .help("Also rename the linked meeting (only overwrites a calendar-copied title)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Event identity

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            calendarLine
            timeLine
            if let joinURL = event.meetingURL {
                joinLine(joinURL)
            }
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var calendarLine: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(calendarColor ?? MuesliTheme.accent)
                .frame(width: 9, height: 9)
            if let calendar = calendarModel {
                Text(calendar.title)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                if let account = accountModel {
                    Text("· \(account.title)")
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                }
            } else {
                Text("Calendar")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var timeLine: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)
                .padding(.top, 1)
            Text(timeDescription)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func joinLine(_ joinURL: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "video")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.accent)
            Button {
                NSWorkspace.shared.open(joinURL)
            } label: {
                Text("Join meeting")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.accent)
            }
            .buttonStyle(.plain)
            .help("Open \(joinURL.absoluteString)")
            .accessibilityLabel("Open join link")
        }
    }

    private var cancelledBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(MuesliTheme.transcribing)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("This event was cancelled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Any recording for it can still be opened below.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.transcribing.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.transcribing.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - State zone

    /// The meeting command zone: one primary block per linkage state,
    /// mirroring the calendar rows' chips but with room for the full control
    /// set (record, join & record, pause/stop, open document, summary).
    @ViewBuilder
    private var stateSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            switch linkage.state {
            case .upcoming, .now:
                upcomingNowZone
            case .recording:
                recordingZone
            case .processing:
                processingZone
            case .completed:
                recordedZone()
            case .missed:
                missedZone
            case .cancelledEvent:
                // Cancelled but recorded: the meeting stays reachable.
                if let meeting = linkedMeeting {
                    recordedZone(openMeeting: meeting)
                } else {
                    cancelledEventZone
                }
            case .noEvent:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var upcomingNowZone: some View {
        if linkage.canRecord {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                Button {
                    startRecording()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Record This Meeting")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(MuesliTheme.accentContent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(MuesliTheme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                .help("Start recording and transcribing this meeting")

                if let joinURL = event.meetingURL {
                    Button {
                        controller.joinAndRecord(
                            title: event.title,
                            meetingURL: joinURL,
                            endDate: event.endDate,
                            calendarOccurrence: event.resolvedCalendarOccurrence,
                            presentation: .foregroundNotes
                        )
                        onClose()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "video")
                                .font(.system(size: 12, weight: .semibold))
                            Text("Join & Record")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(MuesliTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(MuesliTheme.accent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        .overlay(
                            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                .strokeBorder(MuesliTheme.accent.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    .help("Open the join link and start recording")
                }
            }
        } else if let meeting = linkedMeeting {
            // Upcoming/now with a pre-existing recording (per-occurrence
            // re-records stay allowed from the row, but not while another
            // session is live).
            recordedZone(openMeeting: meeting)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var recordingZone: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: 8) {
                recordingDot
                Text(statusLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textPrimary)
                if isPreparing, let startStatus = appState.meetingStartStatus {
                    Text(startStatus)
                        .font(MuesliTheme.caption())
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .lineLimit(1)
                }
            }

            if let meeting = linkedMeeting {
                if isPreparing {
                    Button {
                        controller.cancelMeetingPreparation()
                    } label: {
                        Text("Cancel Preparation")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textSecondary)
                            .padding(.horizontal, MuesliTheme.spacing12)
                            .padding(.vertical, 7)
                            .background(MuesliTheme.surfacePrimary)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                            .overlay(
                                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Stop preparing this recording without creating a meeting")
                } else if appState.isMeetingRecording {
                    HStack(spacing: 8) {
                        pauseResumeButton
                        stopButton
                        openLiveNotesButton(meeting)
                    }
                } else {
                    openMeetingButton(meeting, label: "Open Meeting")
                }
            }
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.recording.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.recording.opacity(0.35), lineWidth: 1)
        )
    }

    private var pauseResumeButton: some View {
        Button {
            controller.toggleMeetingRecordingPause()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: appState.isMeetingRecordingPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(appState.isMeetingRecordingPaused ? "Resume" : "Pause")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(appState.isMeetingRecordingPaused ? Color.white : MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(appState.isMeetingRecordingPaused ? MuesliTheme.accent : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(appState.isMeetingRecordingPaused ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(appState.isMeetingRecordingPaused ? "Resume recording" : "Pause recording")
    }

    private var stopButton: some View {
        Button {
            controller.stopMeetingRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(MuesliTheme.recording)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
        }
        .buttonStyle(.plain)
        .help("Stop recording")
    }

    private func openLiveNotesButton(_ meeting: MeetingRecord) -> some View {
        Button {
            onClose()
            controller.openActiveMeetingNotes()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10, weight: .semibold))
                Text("Open Live Notes")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(MuesliTheme.textSecondary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Open the live meeting notes")
    }

    @ViewBuilder
    private var processingZone: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Processing recording…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.transcribing)
            }
            if let meeting = linkedMeeting {
                openMeetingButton(meeting, label: "Open Meeting")
            }
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    /// Recorded state: summary status line plus the document + maintenance
    /// actions. Also used for cancelled-but-recorded events.
    @ViewBuilder
    private func recordedZone(openMeeting: MeetingRecord? = nil) -> some View {
        if let meeting = openMeeting ?? linkedMeeting {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                HStack(spacing: 6) {
                    Image(systemName: summaryStatusIcon(for: meeting))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(summaryStatusColor(for: meeting))
                    Text(summaryStatusText(for: meeting))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MuesliTheme.textSecondary)
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                    openMeetingButton(meeting, label: "Open transcript & notes", prominent: true)
                    HStack(spacing: 8) {
                        if hasTranscript(meeting), meeting.status != .recording, meeting.status != .processing {
                            resummarizeButton(meeting)
                        }
                        if hasTranscript(meeting) {
                            cleanupButton
                        }
                    }
                }
            }
        }
    }

    private func openMeetingButton(_ meeting: MeetingRecord, label: String, prominent: Bool = false) -> some View {
        Button {
            onClose()
            controller.showMeetingDocument(id: meeting.id)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: prominent ? "doc.text.fill" : "doc.text")
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(prominent ? MuesliTheme.accentContent : MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(prominent ? MuesliTheme.accent : MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(prominent ? MuesliTheme.accent.opacity(0.35) : MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Open the meeting notes and transcript")
    }

    private func resummarizeButton(_ meeting: MeetingRecord) -> some View {
        Button {
            beginSummary(for: meeting)
        } label: {
            HStack(spacing: 6) {
                if isSummarizing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(isSummarizing ? "Summarizing…" : "Re-summarize")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(MuesliTheme.accent)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(MuesliTheme.accent.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.accent.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSummarizing)
        .help("Regenerate the summary notes from the transcript")
    }

    private var cleanupButton: some View {
        Button {
            showCleanupConfirmation = true
        } label: {
            HStack(spacing: 6) {
                if isCleaningTranscript {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(isCleaningTranscript ? "Cleaning…" : "Clean Up Transcript")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(MuesliTheme.textPrimary)
            .padding(.horizontal, MuesliTheme.spacing12)
            .padding(.vertical, 7)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isCleaningTranscript)
        .help("Clean up the transcript with the configured LLM cleanup backend")
    }

    @ViewBuilder
    private var missedZone: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.minus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text("No recording for this meeting")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(MuesliTheme.textSecondary)
            }
            Text("This event passed without a recording. Catch the next occurrence — or record a manual meeting from the Meetings tab.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(MuesliTheme.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var cancelledEventZone: some View {
        Text("This event was cancelled before it was recorded.")
            .font(MuesliTheme.caption())
            .foregroundStyle(MuesliTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Location

    private var trimmedLocation: String? {
        let trimmed = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func locationLine(_ location: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.textTertiary)
                .padding(.top, 1)
            Text(location)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Attendees

    @ViewBuilder
    private var attendeesSection: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Text("Attendees")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
                .textCase(.uppercase)

            VStack(spacing: 0) {
                ForEach(Array(event.attendees.enumerated()), id: \.element.id) { index, attendee in
                    if index > 0 {
                        Divider()
                            .background(MuesliTheme.surfaceBorder)
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(MuesliTheme.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attendee.displayName)
                                .font(MuesliTheme.callout())
                                .foregroundStyle(MuesliTheme.textPrimary)
                                .lineLimit(1)
                            if let email = attendee.emailAddress, email != attendee.displayName.lowercased() {
                                Text(email)
                                    .font(.system(size: 10))
                                    .foregroundStyle(MuesliTheme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, MuesliTheme.spacing8)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Follow-ups

    @ViewBuilder
    private var followUpSection: some View {
        if linkedMeeting != nil {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                if let parent = parentMeeting {
                    followUpRow(
                        icon: "arrow.turn.up.left",
                        title: "Follow-up of \(parent.title)",
                        help: "Open the parent meeting",
                        openID: parent.id
                    )
                }
                ForEach(childFollowUps) { child in
                    followUpRow(
                        icon: "arrow.turn.down.right",
                        title: "Follow-up: \(child.title)",
                        help: "Open the follow-up meeting",
                        openID: child.id
                    )
                }
            }
        }
    }

    private func followUpRow(icon: String, title: String, help: String, openID: Int64) -> some View {
        Button {
            onClose()
            controller.showMeetingDocument(id: openID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(title)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.accent)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 6)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var parentMeeting: MeetingRecord? {
        guard let parentID = linkedMeeting?.followUpToID else { return nil }
        return appState.meetingRows.first { $0.id == parentID }
    }

    private var childFollowUps: [MeetingRecord] {
        guard let linkedID = linkedMeeting?.id else { return [] }
        return appState.meetingRows
            .filter { $0.followUpToID == linkedID }
            .sorted { $0.startTime < $1.startTime }
    }

    // MARK: - Folder

    @ViewBuilder
    private var folderSection: some View {
        if let folderID = linkedMeeting?.folderID,
           let folder = appState.folders.first(where: { $0.id == folderID }) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
                Text(folder.name)
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, MuesliTheme.spacing8)
            .padding(.vertical, 6)
            .background(MuesliTheme.backgroundRaised)
            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
            .overlay(
                RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Actions

    private func startRecording() {
        guard linkage.canRecord, !busy else { return }
        Task {
            let didStart = await controller.recordCalendarEvent(event)
            if didStart {
                onClose()
            }
        }
    }

    private func beginSummary(for meeting: MeetingRecord) {
        guard !isSummarizing else { return }
        isSummarizing = true
        summaryErrorMessage = nil
        controller.resummarize(meeting: meeting) { result in
            isSummarizing = false
            if case .failure(let error) = result {
                summaryErrorMessage = error.localizedDescription
            }
        }
    }

    private func runTranscriptCleanup() {
        guard let meeting = linkedMeeting, !isCleaningTranscript else { return }
        isCleaningTranscript = true
        cleanupErrorMessage = nil
        Task {
            do {
                try await controller.applyTranscriptCleanup(id: meeting.id)
                isCleaningTranscript = false
            } catch {
                isCleaningTranscript = false
                cleanupErrorMessage = error.localizedDescription
            }
        }
    }

    /// Event title edits commit to the calendar store; a linked meeting
    /// follows through the title-sync path (fresh-copy heuristic) when its
    /// stored title is a stale calendar copy.
    private func commitTitleEdit() {
        let trimmed = editableTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != event.title else {
            editableTitle = event.title
            pendingTitleText = nil
            return
        }
        editableTitle = trimmed
        pendingTitleText = nil

        let renamed = controller.renameCalendarEvent(event, to: trimmed)
        guard renamed else {
            editableTitle = event.title
            return
        }

        if let meeting = linkedMeeting, meeting.title != trimmed, meeting.status != .recording, meeting.status != .processing {
            titleSyncMeetingID = meeting.id
            Task { @MainActor in
                defer { titleSyncMeetingID = nil }
                await controller.syncMeetingTitleWithCalendarEvent(
                    meetingID: meeting.id,
                    event: event.replacingTitle(trimmed)
                )
            }
        }
    }

    // MARK: - Summary status

    private func hasTranscript(_ meeting: MeetingRecord) -> Bool {
        !meeting.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func summaryStatusText(for meeting: MeetingRecord) -> String {
        let hasSummary = !meeting.formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch meeting.status {
        case .recording:
            return appState.isMeetingRecordingPaused ? "Recording paused" : "Recording in progress"
        case .processing:
            return "Processing summary…"
        case .failed:
            return hasSummary ? "Summary ready" : "Summary failed"
        case .noteOnly, .completed:
            return hasSummary ? "Summary ready" : "No summary"
        }
    }

    private func summaryStatusIcon(for meeting: MeetingRecord) -> String {
        let hasSummary = !meeting.formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch meeting.status {
        case .recording:
            return appState.isMeetingRecordingPaused ? "pause.circle.fill" : "record.circle"
        case .processing:
            return "waveform"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .noteOnly, .completed:
            return hasSummary ? "checkmark.circle.fill" : "circle.dashed"
        }
    }

    private func summaryStatusColor(for meeting: MeetingRecord) -> Color {
        let hasSummary = !meeting.formattedNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch meeting.status {
        case .recording:
            return appState.isMeetingRecordingPaused ? MuesliTheme.transcribing : MuesliTheme.recording
        case .processing, .failed:
            return MuesliTheme.transcribing
        case .noteOnly, .completed:
            return hasSummary ? MuesliTheme.success : MuesliTheme.textTertiary
        }
    }

    // MARK: - Derived display state

    private var isPreparing: Bool {
        linkedMeeting?.status == .recording && appState.isMeetingStarting && !appState.isMeetingRecording
    }

    private var statusLabel: String {
        if isPreparing {
            return "Preparing…"
        }
        if appState.isMeetingRecordingPaused {
            return "Paused"
        }
        return "Recording…"
    }

    /// Small red dot that pulses while a recording is live; steady amber
    /// while paused.
    private var recordingDot: some View {
        if appState.isMeetingRecordingPaused {
            return AnyView(
                Circle()
                    .fill(MuesliTheme.transcribing)
                    .frame(width: 8, height: 8)
            )
        }
        return AnyView(
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
                Circle()
                    .fill(MuesliTheme.recording)
                    .frame(width: 8, height: 8)
                    .opacity(0.45 + 0.55 * (0.5 + 0.5 * cos(2 * .pi * phase)))
            }
        )
    }

    private var calendarModel: EKCalendarModel? {
        guard let calendarID = event.calendarID else { return nil }
        return appState.eventKitCalendars.first { $0.id == calendarID }
    }

    private var accountModel: EKAccountModel? {
        guard let accountID = calendarModel?.accountID, !accountID.isEmpty else { return nil }
        return appState.calendarAccounts.first { $0.id == accountID }
    }

    private var calendarColor: Color? {
        guard let hex = calendarModel?.colorHex else { return nil }
        return CalendarEventDetailPanel.color(fromHex: hex)
    }

    private var timeDescription: String {
        let start = event.startDate
        let end = event.endDate
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(CalendarEventDetailPanel.fullDay.string(from: start)), \(CalendarEventDetailPanel.time.string(from: start)) – \(CalendarEventDetailPanel.time.string(from: end)) · \(CalendarEventDetailPanel.durationText(end.timeIntervalSince(start)))"
        }
        return "\(CalendarEventDetailPanel.fullDay.string(from: start)), \(CalendarEventDetailPanel.time.string(from: start)) – \(CalendarEventDetailPanel.fullDay.string(from: end)), \(CalendarEventDetailPanel.time.string(from: end))"
    }

    private func errorBinding(_ source: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { source.wrappedValue != nil },
            set: { if !$0 { source.wrappedValue = nil } }
        )
    }
}

/// Local copy helper: UnifiedCalendarEvent's title is immutable, so a
/// renamed snapshot is rebuilt field-by-field.
private extension UnifiedCalendarEvent {
    func replacingTitle(_ newTitle: String) -> UnifiedCalendarEvent {
        UnifiedCalendarEvent(
            id: id,
            title: newTitle,
            startDate: startDate,
            endDate: endDate,
            isAllDay: isAllDay,
            source: source,
            calendarID: calendarID,
            calendarOccurrence: calendarOccurrence,
            meetingURL: meetingURL,
            attendees: attendees,
            location: location,
            isCancelled: isCancelled,
            isDeclined: isDeclined
        )
    }
}

// MARK: - Panel formatters + helpers

private enum CalendarEventDetailPanel {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static let fullDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()

    static func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = Int(interval.rounded() / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours) hr \(minutes) min" : "\(hours) hr"
        }
        return minutes > 0 ? "\(minutes) min" : "1 min"
    }

    /// Parses "rrggbb" / "#rrggbb" into a Color; nil on malformed input.
    static func color(fromHex hex: String) -> Color? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let rgb = UInt64(value, radix: 16) else { return nil }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
