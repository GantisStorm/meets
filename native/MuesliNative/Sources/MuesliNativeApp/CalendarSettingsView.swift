import AppKit
import SwiftUI

/// Embedded Apple Calendar manager: lists every EventKit account, expandable
/// to its calendars, with per-calendar enable toggles, rename, and delete.
///
/// Removing an *account* is deliberately not offered here — EventKit cannot
/// remove an account (only its calendars), so the UI routes account removal to
/// System Settings > Internet Accounts. Deleting a *calendar* (when EventKit
/// allows) removes it from the connected account on every device it syncs to.
struct CalendarSettingsView: View {
    let appState: AppState
    let controller: MuesliController
    let onClose: () -> Void

    /// Accounts expanded to show their calendars. Defaults to every account
    /// when access is first granted so calendars are visible immediately.
    @State private var expandedAccountIDs: Set<String> = []
    @State private var expandedInitialized = false
    /// Calendar currently being renamed, keyed by calendar id.
    @State private var renamingCalendarID: String?
    @State private var renameDraft = ""
    /// Calendar pending destructive-delete confirmation.
    @State private var calendarPendingDeletion: EKCalendarModel?
    /// Calendar whose delete failed (shows error alert).
    @State private var deleteErrorMessage: String?
    /// Calendar whose rename failed (shows error alert).
    @State private var renameErrorMessage: String?
    /// Tracks the in-flight toggle per calendar id so a rapid re-click cannot
    /// race the persisted disabled set.
    @State private var pendingToggleCalendarIDs: Set<String> = []
    @State private var isRequestingAccess = false
    @State private var hasAttemptedInitialAccess = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().background(MuesliTheme.surfaceBorder)

            content
        }
        .background(MuesliTheme.backgroundBase)
        .alert(
            "Delete “\(calendarPendingDeletion?.title ?? "")”?",
            isPresented: Binding(
                get: { calendarPendingDeletion != nil },
                set: { if !$0 { calendarPendingDeletion = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                calendarPendingDeletion = nil
            }
            Button("Delete Calendar", role: .destructive) {
                confirmDeletePendingCalendar()
            }
        } message: {
            Text("This removes the calendar and its events from the connected account, including on your other devices. This cannot be undone.")
        }
        .alert(
            "Couldn't Delete Calendar",
            isPresented: Binding(
                get: { deleteErrorMessage != nil },
                set: { if !$0 { deleteErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                deleteErrorMessage = nil
            }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .alert(
            "Couldn't Rename Calendar",
            isPresented: Binding(
                get: { renameErrorMessage != nil },
                set: { if !$0 { renameErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                renameErrorMessage = nil
            }
        } message: {
            Text(renameErrorMessage ?? "")
        }
        .onAppear {
            performInitialAccessIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple Calendar")
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Choose the calendars Meets watches for upcoming meetings. Disabled calendars are hidden — no notifications, no Coming Up, no meeting detection.")
                    .font(MuesliTheme.callout())
                    .foregroundStyle(MuesliTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: MuesliTheme.spacing16)

            Button("Done") {
                onClose()
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.borderedProminent)
            .tint(MuesliTheme.accent)
            .foregroundStyle(MuesliTheme.accentContent)
        }
        .padding(MuesliTheme.spacing20)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch appState.calendarAuthorization {
        case .fullAccess:
            authorizedContent
        case .writeOnly:
            writeOnlyAccessContent
        case .denied:
            deniedContent
        case .unknown:
            unknownContent
        }
    }

    private var authorizedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    if appState.calendarAccounts.isEmpty {
                        emptyAccountsState
                    } else {
                        ForEach(appState.calendarAccounts) { account in
                            accountSection(account)
                        }
                    }
                }
                .padding(MuesliTheme.spacing20)
            }

            Divider().background(MuesliTheme.surfaceBorder)

            footer
        }
    }

    private var emptyAccountsState: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            HStack(spacing: MuesliTheme.spacing8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textSecondary)
                Text("No calendars found")
                    .font(MuesliTheme.body())
                    .foregroundStyle(MuesliTheme.textPrimary)
            }
            Text("Add a calendar account in System Settings > Internet Accounts, then reopen this window.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MuesliTheme.spacing16)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    private var writeOnlyAccessContent: some View {
        VStack(spacing: MuesliTheme.spacing16) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(MuesliTheme.textTertiary)
            VStack(spacing: MuesliTheme.spacing4) {
                Text("Calendar access is limited")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Meets can only add events. Full access is required to read your calendars and detect upcoming meetings.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            Button("Allow Full Access") {
                requestFullAccess()
            }
            .buttonStyle(.borderedProminent)
            .tint(MuesliTheme.accent)
            .foregroundStyle(MuesliTheme.accentContent)
            .disabled(isRequestingAccess)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MuesliTheme.spacing24)
    }

    private var deniedContent: some View {
        VStack(spacing: MuesliTheme.spacing16) {
            Spacer()
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 34))
                .foregroundStyle(MuesliTheme.textTertiary)
            VStack(spacing: MuesliTheme.spacing4) {
                Text("Calendar access is off")
                    .font(MuesliTheme.headline())
                    .foregroundStyle(MuesliTheme.textPrimary)
                Text("Meets can't see your calendars. Enable Calendar access in System Settings > Privacy & Security, or re-request it here.")
                    .font(MuesliTheme.caption())
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, MuesliTheme.spacing24)
            Button("Request Access") {
                requestFullAccess()
            }
            .buttonStyle(.borderedProminent)
            .tint(MuesliTheme.accent)
            .foregroundStyle(MuesliTheme.accentContent)
            .disabled(isRequestingAccess)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(MuesliTheme.spacing24)
    }

    private var unknownContent: some View {
        VStack(spacing: MuesliTheme.spacing16) {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("Checking Calendar access…")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Image(systemName: "arrow.up.forward.square")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("Remove an account in System Settings > Internet Accounts.")
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
            Spacer()
            Button {
                controller.openSystemCalendarAccountSettings()
            } label: {
                Text("Open Account Settings…")
                    .font(MuesliTheme.captionMedium())
                    .foregroundStyle(MuesliTheme.accent)
            }
            .buttonStyle(.plain)
            .help("Open System Settings > Internet Accounts")
        }
        .padding(.horizontal, MuesliTheme.spacing20)
        .padding(.vertical, MuesliTheme.spacing12)
    }

    // MARK: - Accounts

    @ViewBuilder
    private func accountSection(_ account: EKAccountModel) -> some View {
        let accountCalendars = calendars(for: account)
        let isExpanded = expandedAccountIDs.contains(account.id)
        VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedAccountIDs.remove(account.id)
                    } else {
                        expandedAccountIDs.insert(account.id)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .frame(width: 8)
                    Image(systemName: accountIconName(for: account))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textPrimary)
                            .lineLimit(1)
                        Text(accountCalendarCountLabel(for: account, calendars: accountCalendars))
                            .font(.system(size: 11))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(account.typeLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(MuesliTheme.surfacePrimary)
                        .clipShape(RoundedRectangle(cornerRadius: 99))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse account" : "Show calendars")

            if isExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(accountCalendars) { calendar in
                        calendarRow(calendar)
                    }
                }
                .padding(.leading, 34)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(MuesliTheme.surfaceBorder)
                        .frame(width: 1)
                }
            }
        }
    }

    private func calendars(for account: EKAccountModel) -> [EKCalendarModel] {
        appState.eventKitCalendars
            .filter { $0.accountID == account.id }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func accountCalendarCountLabel(for account: EKAccountModel, calendars: [EKCalendarModel]) -> String {
        let count = calendars.count
        let suffix = count == 1 ? "calendar" : "calendars"
        if count == 0 {
            return "0 calendars"
        }
        let enabledCount = calendars.filter { !disabledCalendarIDs.contains($0.id) }.count
        if enabledCount == 0 {
            return "\(count) \(suffix) · all disabled"
        }
        if enabledCount == count {
            return "\(count) \(suffix) · all enabled"
        }
        return "\(count) \(suffix) · \(enabledCount) enabled"
    }

    private func accountIconName(for account: EKAccountModel) -> String {
        let normalized = account.typeLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "icloud" {
            return "icloud"
        }
        if normalized == "subscribed calendars" {
            return "calendar.badge.clock"
        }
        if normalized == "birthdays" {
            return "gift"
        }
        if normalized == "on my mac" || normalized == "local" {
            return "desktopcomputer"
        }
        if normalized == "exchange" {
            return "building.2"
        }
        if normalized == "caldav" {
            return "server.rack"
        }
        return "calendar"
    }

    // MARK: - Calendar rows

    @ViewBuilder
    private func calendarRow(_ calendar: EKCalendarModel) -> some View {
        let isEnabled = isCalendarEnabled(calendar)
        let isLocked = !calendar.isBirthdays
            && (calendar.isSubscription || calendar.isImmutable || !calendar.allowsContentModifications)
        HStack(spacing: 10) {
            Circle()
                .fill(calendarColor(calendar))
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                if renamingCalendarID == calendar.id {
                    renameField(calendar)
                } else {
                    Text(calendar.title)
                        .font(MuesliTheme.body())
                        .foregroundStyle(isEnabled ? MuesliTheme.textPrimary : MuesliTheme.textTertiary)
                        .lineLimit(1)
                    if calendar.isBirthdays || calendar.isSubscription {
                        calendarSubtitle(calendar)
                    }
                }
            }
            .layoutPriority(1)

            Spacer(minLength: MuesliTheme.spacing8)

            if isLocked {
                lockIndicator
            } else {
                Toggle("", isOn: Binding(
                    get: { isEnabled },
                    set: { newValue in
                        toggleCalendarEnabled(calendar, enabled: newValue)
                    }
                ))
                .toggleStyle(.switch)
                .tint(MuesliTheme.accent)
                .labelsHidden()
                .controlSize(.small)
                .disabled(pendingToggleCalendarIDs.contains(calendar.id))
                .help(isEnabled ? "Hide this calendar from Meets" : "Watch this calendar for upcoming meetings")
            }

            overflowMenu(calendar)
        }
        .padding(.vertical, 4)
    }

    private var disabledCalendarIDs: Set<String> {
        Set(appState.config.disabledCalendarIDs)
    }

    private func isCalendarEnabled(_ calendar: EKCalendarModel) -> Bool {
        !disabledCalendarIDs.contains(calendar.id)
    }

    /// sRGB color for a calendar's stored hex ("rrggbb", no "#"), with a
    /// neutral fallback for calendars without a color.
    private func calendarColor(_ calendar: EKCalendarModel) -> Color {
        guard let colorHex = calendar.colorHex, colorHex.count == 6,
              let value = UInt64(colorHex, radix: 16) else {
            return MuesliTheme.textTertiary
        }
        return Color(hex: Int(value))
    }

    @ViewBuilder
    private func calendarSubtitle(_ calendar: EKCalendarModel) -> some View {
        HStack(spacing: 4) {
            if calendar.isSubscription {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9))
            }
            Text(calendar.isBirthdays ? "Birthdays" : "Subscribed")
                .font(.system(size: 10))
        }
        .foregroundStyle(MuesliTheme.textTertiary)
    }

    private var lockIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("Read-only")
                .font(.system(size: 10))
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .help("This calendar is managed by the system and cannot be changed here.")
    }

    @ViewBuilder
    private func renameField(_ calendar: EKCalendarModel) -> some View {
        HStack(spacing: 6) {
            TextField("Calendar name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
                .font(MuesliTheme.body())
                .frame(width: 220)
                .onSubmit {
                    commitRename(calendar)
                }
            Button("Save") {
                commitRename(calendar)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(MuesliTheme.accent)
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button {
                renamingCalendarID = nil
                renameDraft = ""
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Cancel rename")
        }
    }

    @ViewBuilder
    private func overflowMenu(_ calendar: EKCalendarModel) -> some View {
        Menu {
            if !calendar.isImmutable, calendar.allowsContentModifications {
                Button {
                    startRenaming(calendar)
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    calendarPendingDeletion = calendar
                } label: {
                    Label("Delete…", systemImage: "trash")
                }
                .help("Delete from connected account and devices")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MuesliTheme.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(calendar.isImmutable || !calendar.allowsContentModifications)
        .help(calendar.isImmutable || !calendar.allowsContentModifications
            ? "This calendar is read-only"
            : "Calendar options")
    }

    // MARK: - Actions

    private func startRenaming(_ calendar: EKCalendarModel) {
        renamingCalendarID = calendar.id
        renameDraft = calendar.title
        renameErrorMessage = nil
    }

    private func commitRename(_ calendar: EKCalendarModel) {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != calendar.title else {
            renamingCalendarID = nil
            renameDraft = ""
            return
        }
        let renamed = CalendarEventKitManager.shared.renameCalendar(id: calendar.id, to: trimmed)
        renamingCalendarID = nil
        renameDraft = ""
        if renamed {
            Task {
                await controller.refreshEventKitCalendars()
                await controller.refreshUpcomingCalendarEvents()
            }
        } else {
            renameErrorMessage = "macOS could not rename this calendar. It may be read-only or the change failed to save."
        }
    }

    private func toggleCalendarEnabled(_ calendar: EKCalendarModel, enabled: Bool) {
        guard !pendingToggleCalendarIDs.contains(calendar.id) else { return }
        pendingToggleCalendarIDs.insert(calendar.id)
        controller.setCalendarEnabled(id: calendar.id, enabled: enabled)
        // Let the persisted config propagate (Observable + config write are
        // synchronous), then release the latch for future clicks.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            pendingToggleCalendarIDs.remove(calendar.id)
        }
    }

    private func confirmDeletePendingCalendar() {
        guard let calendar = calendarPendingDeletion else { return }
        calendarPendingDeletion = nil
        Task {
            if let errorMessage = await controller.deleteCalendar(id: calendar.id) {
                deleteErrorMessage = errorMessage
            }
        }
    }

    private func requestFullAccess() {
        guard !isRequestingAccess else { return }
        isRequestingAccess = true
        Task {
            await controller.refreshCalendarAccess()
            isRequestingAccess = false
            if appState.calendarAuthorization == .fullAccess {
                await controller.refreshEventKitCalendars()
                expandAllAccounts()
            }
        }
    }

    private func performInitialAccessIfNeeded() {
        guard !hasAttemptedInitialAccess else { return }
        hasAttemptedInitialAccess = true
        let auth = appState.calendarAuthorization
        if auth == .fullAccess {
            // Authorized accounts only appear after a calendar fetch; ensure
            // the snapshot is fresh every time the manager opens.
            Task {
                await controller.refreshEventKitCalendars()
                expandAllAccounts()
            }
        } else if auth == .unknown {
            requestFullAccess()
        }
    }

    private func expandAllAccounts() {
        guard !expandedInitialized else { return }
        expandedInitialized = true
        expandedAccountIDs = Set(appState.calendarAccounts.map(\.id))
    }
}
