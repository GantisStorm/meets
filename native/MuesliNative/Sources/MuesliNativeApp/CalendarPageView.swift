import SwiftUI
import MuesliCore

/// Apple-Calendar-style dashboard page backed entirely by EventKit state
/// (appState.calendarEvents / eventKitCalendars). Copy is calendar-neutral —
/// no provider-specific wording.
struct CalendarPageView: View {
    let appState: AppState
    let controller: MuesliController

    @State private var pageMode: CalendarPageMode = .month
    @State private var visibleMonth: Date
    @State private var selectedDate: Date
    /// Client-side filter for the list view (All | Upcoming | Past | Recorded | Unrecorded).
    @State private var listFilter: CalendarListFilter = .all
    /// Incremented to ask the list view to jump to today's section.
    @State private var listTodayScrollRequest = 0
    /// The event whose detail panel is presented, if any. Single-clicking a
    /// day/list row opens the panel (rows previously jumped straight to the
    /// meeting document); month chip taps keep drilling to the day.
    @State private var selectedEvent: UnifiedCalendarEvent?

    init(appState: AppState, controller: MuesliController) {
        self.appState = appState
        self.controller = controller
        let today = Calendar.current.startOfDay(for: Date())
        _selectedDate = State(initialValue: today)
        _visibleMonth = State(initialValue: CalendarPageLogic.monthStart(of: today))
    }

    var body: some View {
        Group {
            if appState.calendarAuthorization != .fullAccess {
                calendarAccessView
            } else {
                pageContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MuesliTheme.backgroundBase)
        .task {
            await controller.refreshCalendarEvents()
        }
        .onChange(of: appState.config.disabledCalendarIDs) { _, _ in
            Task { await controller.refreshCalendarEvents() }
        }
        .onChange(of: appState.calendarAuthorization) { _, authorization in
            if authorization == .fullAccess {
                Task { await controller.refreshCalendarEvents() }
            }
        }
        .onChange(of: appState.calendarDeepLinkFilter) { _, filter in
            guard let filter else { return }
            pageMode = .list
            if let mapped = CalendarListFilter(rawValue: filter) {
                listFilter = mapped
            }
            appState.calendarDeepLinkFilter = nil
        }
        .sheet(item: $selectedEvent) { event in
            CalendarEventDetailView(
                appState: appState,
                controller: controller,
                event: event,
                onClose: { selectedEvent = nil }
            )
        }
    }

    // MARK: - Unauthorized state

    @ViewBuilder
    private var calendarAccessView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing24) {
                PageTitle("Calendar")

                VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                    Image(systemName: "calendar")
                        .font(.system(size: 30, weight: .thin))
                        .foregroundStyle(MuesliTheme.textTertiary)

                    Text(accessTitle)
                        .font(MuesliTheme.title3())
                        .foregroundStyle(MuesliTheme.textPrimary)

                    Text(accessMessage)
                        .font(MuesliTheme.callout())
                        .foregroundStyle(MuesliTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 480, alignment: .leading)

                    HStack(spacing: MuesliTheme.spacing12) {
                        Button {
                            Task {
                                await controller.refreshCalendarAccess(requestIfUndetermined: true)
                                if appState.calendarAuthorization == .fullAccess {
                                    await controller.refreshCalendarEvents()
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if appState.isCalendarPageLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(accessButtonTitle)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(MuesliTheme.backgroundBase)
                            .padding(.horizontal, MuesliTheme.spacing16)
                            .padding(.vertical, MuesliTheme.spacing8)
                            .background(MuesliTheme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isCalendarPageLoading)

                        if appState.calendarAuthorization == .denied {
                            Button {
                                controller.openSystemCalendarAccountSettings()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.right.square")
                                        .font(.system(size: 11))
                                    Text("Open System Settings")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(MuesliTheme.textPrimary)
                                .padding(.horizontal, MuesliTheme.spacing16)
                                .padding(.vertical, MuesliTheme.spacing8)
                                .background(MuesliTheme.surfacePrimary)
                                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                                .overlay(
                                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(MuesliTheme.spacing24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MuesliTheme.backgroundRaised)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerXL))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerXL)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.top, MuesliTheme.pageTop)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var accessTitle: String {
        switch appState.calendarAuthorization {
        case .unknown:
            return "Calendar access needed"
        case .writeOnly:
            return "Read access needed"
        case .denied:
            return "Calendar access is off"
        case .fullAccess:
            return ""
        }
    }

    private var accessMessage: String {
        switch appState.calendarAuthorization {
        case .unknown:
            return "Meets reads your Apple Calendar so events, meetings, and recordings appear in one place. Nothing leaves this Mac."
        case .writeOnly:
            return "macOS only granted Meets write access to your calendar. Grant full access to see your events here."
        case .denied:
            return "Calendar access was denied. Open System Settings and allow Meets to read your calendar, then try again."
        case .fullAccess:
            return ""
        }
    }

    private var accessButtonTitle: String {
        appState.calendarAuthorization == .unknown ? "Allow Calendar Access" : "Try Again"
    }

    // MARK: - Authorized content

    private var pageContent: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
            PageTitle("Calendar")
            toolbar

            if pageMode == .list {
                listFilterBar
            }

            Group {
                switch pageMode {
                case .month:
                    monthView
                case .day:
                    dayView
                case .list:
                    listView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 40)
        .padding(.top, MuesliTheme.pageTop)
    }

    // MARK: - List filter bar

    private var listFilterBar: some View {
        HStack(spacing: MuesliTheme.spacing12) {
            Picker("Filter events", selection: $listFilter) {
                ForEach(CalendarListFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Filter events")

            Text(listResultsCountText)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textTertiary)
                .monospacedDigit()
                .fixedSize()

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 1000, alignment: .leading)
    }

    private var listResultsCountText: String {
        let count = filteredListSections.reduce(0) { $0 + $1.events.count }
        if count == 1 {
            return "1 event"
        }
        return "\(count) events"
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: MuesliTheme.spacing16) {
                modePicker
                Spacer(minLength: 0)
                toolbarTrailing
            }
            VStack(alignment: .leading, spacing: MuesliTheme.spacing8) {
                modePicker
                HStack {
                    Spacer(minLength: 0)
                    toolbarTrailing
                }
            }
        }
    }

    private var modePicker: some View {
        Picker("Calendar view", selection: $pageMode) {
            ForEach(CalendarPageMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 240)
        .accessibilityLabel("Calendar view")
    }

    @ViewBuilder
    private var toolbarTrailing: some View {
        HStack(spacing: MuesliTheme.spacing8) {
            Toggle("Hide cancelled", isOn: hideCancelledBinding)
                .toggleStyle(.checkbox)
                .font(MuesliTheme.caption())
                .foregroundStyle(MuesliTheme.textSecondary)
                .fixedSize()
                .help("Hide cancelled and declined events from the calendar")

            if appState.isCalendarPageLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if pageMode != .list {
                navButton(direction: -1)
            }

            Button {
                goToToday()
            } label: {
                Text("Today")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.horizontal, MuesliTheme.spacing12)
                    .padding(.vertical, 5)
                    .background(MuesliTheme.surfacePrimary)
                    .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                    .overlay(
                        RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                            .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("Jump to today")

            if pageMode != .list {
                navButton(direction: 1)
            }
        }
    }

    private func navButton(direction: Int) -> some View {
        Button {
            stepNavigation(direction: direction)
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 26, height: 24)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall))
                .overlay(
                    RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help(direction < 0 ? "Previous" : "Next")
    }

    private func stepNavigation(direction: Int) {
        let calendar = Calendar.current
        switch pageMode {
        case .month:
            if let month = calendar.date(byAdding: .month, value: direction, to: visibleMonth) {
                visibleMonth = CalendarPageLogic.monthStart(of: month)
            }
        case .day:
            if let day = calendar.date(byAdding: .day, value: direction, to: selectedDate) {
                selectedDate = calendar.startOfDay(for: day)
            }
        case .list:
            break
        }
    }

    private func goToToday() {
        let today = Calendar.current.startOfDay(for: Date())
        switch pageMode {
        case .month:
            visibleMonth = CalendarPageLogic.monthStart(of: today)
            selectedDate = today
        case .day:
            selectedDate = today
        case .list:
            listTodayScrollRequest &+= 1
        }
    }

    // MARK: - Month

    private var monthView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
                Text(CalendarPageLogic.monthTitleFormatter.string(from: visibleMonth))
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)
                    .padding(.bottom, 2)

                HStack(spacing: 2) {
                    ForEach(0..<7, id: \.self) { column in
                        Text(weekdayLabel(column: column))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(MuesliTheme.textTertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 4)

                let weeks = monthWeeks
                // Eager Grid, not LazyVGrid: lazy vertical containers inside a
                // ScrollView collapse when children carry unbounded
                // (.infinity) heights — only the first row rendered. Grid
                // always lays out every week, and cell heights are bounded
                // below, so all 5–6 weeks of the month are always visible.
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    ForEach(weeks.indices, id: \.self) { weekIndex in
                        GridRow {
                            ForEach(weeks[weekIndex].indices, id: \.self) { cellIndex in
                                monthDayCell(weeks[weekIndex][cellIndex])
                            }
                        }
                    }
                }

                if appState.calendarEvents.isEmpty {
                    monthEmptyState
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func monthDayCell(_ cell: CalendarPageDayCell) -> some View {
        let isToday = cell.date.map { Calendar.current.isDateInToday($0) } ?? false
        let isSelected = cell.date.map { Calendar.current.isDate($0, inSameDayAs: selectedDate) } ?? false
        let dayNumber = cell.date.map { CalendarPageLogic.dayNumberFormatter.string(from: $0) } ?? ""
        let events = cell.events.sorted { $0.startDate < $1.startDate }
        let dayHelp = cell.date.map { CalendarPageLogic.fullDayFormatter.string(from: $0) } ?? ""

        func openDay() {
            if let date = cell.date {
                selectedDate = date
                pageMode = .day
            }
        }

        return VStack(alignment: .leading, spacing: 4) {
            Button(action: openDay) {
                Text(dayNumber)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected
                        ? MuesliTheme.accentContent
                        : (cell.isCurrentMonth ? MuesliTheme.textPrimary : MuesliTheme.textTertiary))
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(isSelected ? MuesliTheme.accent : Color.clear)
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(isToday ? MuesliTheme.accent : Color.clear, lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(events.prefix(CalendarPageLogic.maxChipsPerDay)) { event in
                    monthChip(event)
                }
                if events.count > CalendarPageLogic.maxChipsPerDay {
                    Text("+\(events.count - CalendarPageLogic.maxChipsPerDay) more")
                        .font(.system(size: 9))
                        .foregroundStyle(MuesliTheme.textTertiary)
                        .padding(.leading, 2)
                }
            }
            Spacer(minLength: 0)
        }
        // Bounded height so eager Grid rows are deterministic; content taller
        // than the row clips only in extreme cases (4+ chips on one day),
        // which the "+N more" line absorbs.
        .frame(maxWidth: .infinity, minHeight: CalendarPageLogic.monthRowHeight, alignment: .topLeading)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .fill(backgroundFill(isSelected: isSelected, isToday: isToday, isCurrentMonth: cell.isCurrentMonth))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerSmall)
                .strokeBorder(cell.isCurrentMonth ? MuesliTheme.surfaceBorder.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        // Blank cell area (and "+N more") opens the day, matching the former
        // whole-cell button; chip rows and the record glyph are their own
        // buttons so a record tap never also navigates.
        .onTapGesture(perform: openDay)
        .help(dayHelp)
    }

    private func backgroundFill(isSelected: Bool, isToday: Bool, isCurrentMonth: Bool) -> Color {
        if isSelected {
            return MuesliTheme.surfaceSelected.opacity(0.5)
        }
        if isCurrentMonth {
            return MuesliTheme.backgroundRaised.opacity(0.55)
        }
        return .clear
    }

    private func monthChip(_ event: UnifiedCalendarEvent) -> some View {
        let color = calendarColor(for: event) ?? MuesliTheme.accent
        let linkage = linkage(for: event)
        let cancelled = event.isCancelled || event.isDeclined

        return HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(event.title)
                .font(.system(size: 9.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(cancelled, color: MuesliTheme.textSecondary)
                .foregroundStyle(cancelled ? MuesliTheme.textTertiary : MuesliTheme.textPrimary.opacity(0.9))

            if cancelled {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(MuesliTheme.textTertiary)
            }

            Spacer(minLength: 2)

            // Compact state indicator; only `.recording` / `.processing` /
            // `.completed` get a symbol so recorded days stay scannable.
            switch linkage.state {
            case .upcoming, .now:
                if linkage.canRecord {
                    monthRecordGlyph(event)
                }
            case .recording:
                pulsingRecordingDot(size: 6)
            case .processing:
                ProgressView()
                    .controlSize(.mini)
            case .completed:
                Image(systemName: "waveform")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(MuesliTheme.accent)
            default:
                EmptyView()
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(cancelled ? 0.6 : 1)
    }

    /// Tiny trailing record affordance on month chips — a full "Record"
    /// capsule doesn't fit a chip, so this is a small round record icon.
    /// Day/list rows carry the labeled button.
    private func monthRecordGlyph(_ event: UnifiedCalendarEvent) -> some View {
        let busy = appState.isMeetingRecording || appState.isMeetingStarting
        return Button {
            Task {
                await controller.recordCalendarEvent(event)
            }
        } label: {
            Image(systemName: "record.circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(MuesliTheme.accent)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("Record \(event.title)")
        .accessibilityLabel("Record \(event.title)")
        .fixedSize()
    }

    private var monthEmptyState: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Image(systemName: "calendar")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("No calendar events")
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textSecondary)
            Text("Events from your enabled calendars will appear here once they sync.")
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(MuesliTheme.spacing24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerXL))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerXL)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    // MARK: - Day

    private var dayView: some View {
        let dayEvents = eventsForDay(selectedDate)
        let sections = CalendarPageLogic.hourSections(from: dayEvents)
        let meetingLookup = meetingsByCalendarEventID
        return ScrollView {
            VStack(alignment: .leading, spacing: MuesliTheme.spacing16) {
                Text(CalendarPageLogic.fullDayFormatter.string(from: selectedDate))
                    .font(MuesliTheme.title2())
                    .foregroundStyle(MuesliTheme.textPrimary)

                if dayEvents.isEmpty {
                    dayEmptyState
                } else {
                    VStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                        ForEach(sections, id: \.hour) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.hourLabel)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(MuesliTheme.textTertiary)
                                    .textCase(.uppercase)
                                    .padding(.leading, 2)
                                VStack(spacing: 8) {
                                    ForEach(section.events) { event in
                                        eventRow(event, meeting: meetingLookup[event.id])
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var dayEmptyState: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text("No events this day")
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(MuesliTheme.spacing24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerXL))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerXL)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    // MARK: - List

    private var listView: some View {
        let sections = filteredListSections
        let meetingLookup = meetingsByCalendarEventID
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: MuesliTheme.spacing20) {
                    if sections.isEmpty {
                        listEmptyState
                    } else {
                        ForEach(sections) { section in
                            listSection(section, meetingLookup: meetingLookup)
                                .id(listDayID(section.date))
                        }
                    }
                }
                .frame(maxWidth: 1000, alignment: .leading)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: listTodayScrollRequest) { _, _ in
                let today = Calendar.current.startOfDay(for: Date())
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(listDayID(today), anchor: .top)
                }
            }
        }
    }

    @ViewBuilder
    private func listSection(_ section: CalendarPageDaySection, meetingLookup: [String: MeetingRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(section.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(section.isToday ? MuesliTheme.accent : MuesliTheme.textPrimary)

                if section.isToday {
                    Text("Today")
                        .font(.system(size: 9, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(MuesliTheme.accentContent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MuesliTheme.accent)
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)
                Text("\(section.events.count)")
                    .font(MuesliTheme.caption())
                    .monospacedDigit()
                    .foregroundStyle(MuesliTheme.textTertiary)
                    .help("\(section.events.count) event\(section.events.count == 1 ? "" : "s")")
            }
            .padding(.horizontal, 2)

            VStack(spacing: 6) {
                ForEach(section.events) { event in
                    eventRow(event, meeting: meetingLookup[event.id], dimmedWhenPast: true)
                }
            }
        }
    }

    private var filteredListSections: [CalendarPageDaySection] {
        listSections.compactMap { section in
            let filtered = section.events.filter { event in
                switch listFilter {
                case .all:
                    return true
                case .upcoming:
                    return event.endDate >= Date()
                case .past:
                    return event.endDate < Date()
                case .recorded:
                    return linkage(for: event).linkedMeeting != nil
                case .unrecorded:
                    return linkage(for: event).linkedMeeting == nil
                }
            }
            guard !filtered.isEmpty else { return nil }
            return CalendarPageDaySection(
                date: section.date,
                isToday: section.isToday,
                title: section.title,
                events: filtered
            )
        }
    }

    private var listEmptyState: some View {
        VStack(alignment: .leading, spacing: MuesliTheme.spacing12) {
            Image(systemName: listFilter == .all ? "calendar" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(MuesliTheme.textTertiary)
            Text(listEmptyTitle)
                .font(MuesliTheme.title3())
                .foregroundStyle(MuesliTheme.textSecondary)
            Text(listEmptyMessage)
                .font(MuesliTheme.callout())
                .foregroundStyle(MuesliTheme.textTertiary)
        }
        .padding(MuesliTheme.spacing24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MuesliTheme.backgroundRaised)
        .clipShape(RoundedRectangle(cornerRadius: MuesliTheme.cornerXL))
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerXL)
                .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
        )
    }

    /// Persisted in AppConfig (survives relaunch + view switches).
    private var hideCancelledBinding: Binding<Bool> {
        Binding(
            get: { appState.config.calendarHideCancelled },
            set: { newValue in controller.updateConfig { $0.calendarHideCancelled = newValue } }
        )
    }

    private var listEmptyTitle: String {
        if listFilter != .all {
            return "No \(listFilter.title.lowercased()) events"
        }
        return hideCancelledBinding.wrappedValue ? "No matching events" : "No calendar events"
    }

    private var listEmptyMessage: String {
        if listFilter == .recorded {
            return "Record a meeting from an event and it will appear here."
        }
        if listFilter == .unrecorded {
            return "Every event in this window already has a recording."
        }
        if listFilter != .all {
            return "No events match this filter right now. Try another filter."
        }
        return hideCancelledBinding.wrappedValue
            ? "All events in this window are cancelled. Turn off Hide cancelled to see them."
            : "Events from your enabled calendars will appear here once they sync."
    }

    // MARK: - Shared event row

    /// Derives the linkage view-model for an event. All rows/chips in this
    /// page derive through the same helper so the list, day, and month views
    /// always agree (and update together with `appState`).
    private func linkage(for event: UnifiedCalendarEvent) -> MeetingEventLinkage {
        MeetingEventLinkage.derive(
            event: event,
            meetings: appState.meetingRows,
            additionalLinkedMeetingIDs: controller.meetingIDsLinked(toEvent: event),
            isCurrentlyRecording: appState.isMeetingRecording || appState.isMeetingStarting
        )
    }

    @ViewBuilder
    private func eventRow(
        _ event: UnifiedCalendarEvent,
        meeting: MeetingRecord?,
        dimmedWhenPast: Bool = false
    ) -> some View {
        let color = calendarColor(for: event) ?? MuesliTheme.accent
        let linkage = linkage(for: event)
        let isDimmed = (dimmedWhenPast && event.endDate < Date()) || event.isCancelled
        let busy = appState.isMeetingRecording || appState.isMeetingStarting

        let row = HStack(alignment: .top, spacing: 8) {
            Text(CalendarPageLogic.startTimeFormatter.string(from: event.startDate))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isDimmed ? MuesliTheme.textTertiary : MuesliTheme.textSecondary)
                .monospacedDigit()
                .frame(width: 58, alignment: .trailing)
                .padding(.top, 1)

            Circle()
                .fill(isDimmed ? color.opacity(0.35) : color)
                .frame(width: 8, height: 8)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isDimmed ? MuesliTheme.textTertiary : MuesliTheme.textPrimary)
                    .strikethrough(event.isCancelled || event.isDeclined, color: MuesliTheme.textTertiary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(CalendarPageLogic.rangeFormatter.timeRange(for: event))
                        .font(.system(size: 11))
                        .foregroundStyle(isDimmed ? MuesliTheme.textTertiary.opacity(0.8) : MuesliTheme.textSecondary)
                        .lineLimit(1)
                    if event.isCancelled || event.isDeclined {
                        cancelledTag
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            stateTrailingControls(event: event, linkage: linkage, busy: busy)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .fill(MuesliTheme.backgroundRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MuesliTheme.cornerMedium)
                .strokeBorder(linkage.state == .now ? MuesliTheme.accent.opacity(0.45) : MuesliTheme.surfaceBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .opacity(isDimmed ? 0.62 : 1)

        // Whole-row select affordance. Implemented as a tap gesture on the
        // row rather than a wrapping Button: rows that carry trailing
        // interactive controls (Record, join) must not nest buttons, and
        // SwiftUI Buttons inside the row still consume their own taps.
        // Selection opens the event detail panel — the meeting command
        // center — which offers "Open transcript & notes" for recorded
        // meetings (covering fallback matches the stored-key dictionary
        // cannot see).
        row
            .contentShape(Rectangle())
            .onTapGesture {
                openDetailPanel(for: event)
            }
            .help(openRowHelp(event: event, hasMeeting: (meeting ?? linkage.linkedMeeting) != nil))
    }

    /// Picks the row's tap target: selecting the event always opens the
    /// detail panel, except while a live recording is starting/preparing —
    /// the app's start flow opens the notes document itself.
    private func openDetailPanel(for event: UnifiedCalendarEvent) {
        guard !appState.isMeetingStarting else { return }
        selectedEvent = event
    }

    private func openRowHelp(event: UnifiedCalendarEvent, hasMeeting: Bool) -> String {
        if appState.isMeetingStarting {
            return "Recording is starting…"
        }
        if hasMeeting {
            return "Open \(event.title) details"
        }
        return "Show \(event.title) details"
    }

    // MARK: Row state indicator + trailing controls

    /// The pill / dot / tag that summarizes this event's meeting state on the
    /// right edge of the row. Rendering per state:
    ///   upcoming: subtle clock + "Record" (primary action when canRecord)
    ///   now: accent "Record" button
    ///   recording: red dot + "Recording…" (row opens live notes)
    ///   processing: spinner + "Processing…"
    ///   completed: waveform "Recorded" badge (row opens transcript)
    ///   missed: dimmed "No recording" text
    ///   cancelled: strikethrough handled by the title; a cancelled tag is
    ///     shown next to the time and rows keep any recorded meeting openable.
    @ViewBuilder
    private func stateTrailingControls(
        event: UnifiedCalendarEvent,
        linkage: MeetingEventLinkage,
        busy: Bool
    ) -> some View {
        switch linkage.state {
        case .upcoming, .now:
            HStack(spacing: 6) {
                if linkage.canRecord {
                    recordButton(for: event, prominent: linkage.state == .now, busy: busy)
                }
                if let joinURL = linkage.joinURL {
                    joinLinkIcon(joinURL)
                }
            }
            .fixedSize()
        case .recording, .processing, .completed:
            // Recorded rows keep the primary state chip and, when the event
            // carries a join link, a secondary small join icon — the meeting
            // is linkable even after it was recorded.
            HStack(spacing: 6) {
                switch linkage.state {
                case .recording:
                    recordingChip
                case .processing:
                    processingChip
                default:
                    recordingBadge
                }
                if let joinURL = linkage.joinURL {
                    smallJoinLinkIcon(joinURL)
                }
            }
            .fixedSize()
        case .missed:
            Text("No recording")
                .font(.system(size: 10))
                .foregroundStyle(MuesliTheme.textTertiary)
                .fixedSize()
        case .cancelledEvent:
            // A cancelled event that still has a recording keeps the badge so
            // the transcript stays reachable from the row; the title's
            // strikethrough + Cancelled tag carry the cancellation signal.
            // No join affordance on cancelled events.
            if linkage.linkedMeeting != nil {
                recordingBadge
                    .fixedSize()
            } else {
                EmptyView()
            }
        case .noEvent:
            EmptyView()
        }
    }

    private func recordButton(for event: UnifiedCalendarEvent, prominent: Bool, busy: Bool) -> some View {
        Button {
            Task {
                await controller.recordCalendarEvent(event)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: prominent ? "record.circle" : "clock")
                    .font(.system(size: 10, weight: .semibold))
                Text("Record")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(prominent ? MuesliTheme.backgroundBase : MuesliTheme.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(prominent ? MuesliTheme.accent : MuesliTheme.accent.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .help("Record this \(event.title) meeting")
        .fixedSize()
        .accessibilityLabel("Record \(event.title)")
    }

    @ViewBuilder
    private var recordingChip: some View {
        HStack(spacing: 5) {
            pulsingRecordingDot(size: 7)
            Text("Recording…")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(MuesliTheme.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(MuesliTheme.recording.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recording in progress")
    }

    /// Small red dot that pulses while a recording is live.
    private func pulsingRecordingDot(size: CGFloat) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
            Circle()
                .fill(MuesliTheme.recording)
                .frame(width: size, height: size)
                .opacity(0.45 + 0.55 * (0.5 + 0.5 * cos(2 * .pi * phase)))
        }
    }

    @ViewBuilder
    private var processingChip: some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.small)
            Text("Processing…")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(MuesliTheme.transcribing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(MuesliTheme.transcribing.opacity(0.12))
        .clipShape(Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Processing recording")
    }

    @ViewBuilder
    private var cancelledTag: some View {
        Text("Cancelled")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(MuesliTheme.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(MuesliTheme.surfacePrimary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 0.5)
            )
            .fixedSize()
    }

    @ViewBuilder
    private var recordingBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .semibold))
            Text("Recorded")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(MuesliTheme.accent)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(MuesliTheme.accent.opacity(0.12))
        .clipShape(Capsule())
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recorded meeting")
    }

    @ViewBuilder
    private func joinLinkIcon(_ meetingURL: URL) -> some View {
        Button {
            NSWorkspace.shared.open(meetingURL)
        } label: {
            Image(systemName: "video")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Open join link")
        .fixedSize()
        .accessibilityLabel("Open join link")
    }

    /// Compact secondary join icon for rows that already carry a state chip
    /// (recording / processing / recorded); smaller than the primary 24pt
    /// circle used on unrecorded upcoming/now rows.
    @ViewBuilder
    private func smallJoinLinkIcon(_ meetingURL: URL) -> some View {
        Button {
            NSWorkspace.shared.open(meetingURL)
        } label: {
            Image(systemName: "video")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(MuesliTheme.textSecondary)
                .frame(width: 18, height: 18)
                .background(MuesliTheme.surfacePrimary)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(MuesliTheme.surfaceBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Open join link")
        .fixedSize()
        .accessibilityLabel("Open join link")
    }

    // MARK: - Presentation helpers

    /// Shared event source for month, day, and list views. The
    /// hide-cancelled filter is applied here so every view honors it (the
    /// list's section builder also skips cancelled below, but the shared
    /// filter keeps month chips and day rows consistent).
    private var visibleCalendarEvents: [UnifiedCalendarEvent] {
        // Same visibility rules as the Add-to-Event picker: everything except
        // cancelled/declined when the hide toggle is on. All-day events show
        // in both (they are attachable, linkable calendar items).
        guard appState.config.calendarHideCancelled else { return appState.calendarEvents }
        return appState.calendarEvents.filter { !($0.isCancelled || $0.isDeclined) }
    }

    /// Calendar-event → recorded meeting. Events link to meetings by the
    /// calendar event identifier recorded at creation time; recurring
    /// occurrences additionally carry an occurrence eventID. Explicit
    /// "Add to Event" link rows contribute the same keys, so meetings
    /// attached from the meeting detail view surface on their events too.
    private var meetingsByCalendarEventID: [String: MeetingRecord] {
        var map: [String: MeetingRecord] = [:]
        for meeting in appState.meetingRows {
            if let id = meeting.calendarEventID {
                map[id] = meeting
            }
            if let eventID = meeting.calendarOccurrence?.eventID {
                map[eventID] = meeting
            }
        }
        for link in appState.meetingEventLinks {
            for meeting in appState.meetingRows where meeting.id == link.meetingID {
                map[link.eventID] = meeting
            }
            if let occurrenceKey = link.occurrenceKey {
                // Meetings recorded from this exact occurrence (identity keys
                // survive EventKit identifier regeneration) surface on the
                // linked event too.
                for row in appState.meetingRows where row.calendarOccurrence?.identityKey == occurrenceKey {
                    map[link.eventID] = row
                }
            }
        }
        return map
    }

    private func calendarColor(for event: UnifiedCalendarEvent) -> Color? {
        guard let calendarID = event.calendarID,
              let hex = appState.eventKitCalendars.first(where: { $0.id == calendarID })?.colorHex else { return nil }
        return Color(hexString: hex)
    }

    private var monthWeeks: [[CalendarPageDayCell]] {
        let calendar = Calendar.current
        let monthStart = CalendarPageLogic.monthStart(of: visibleMonth)
        guard let dayRange = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
        let daysInMonth = dayRange.count
        let firstWeekday = calendar.component(.weekday, from: monthStart)
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let weekCount = (leading + daysInMonth + 6) / 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart) else { return [] }

        let eventsByDay = eventsGroupedByDay()
        return (0..<weekCount).map { weekIndex in
            (0..<7).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: weekIndex * 7 + offset, to: gridStart) else { return nil }
                let isCurrentMonth = calendar.isDate(date, equalTo: monthStart, toGranularity: .month)
                let dayStart = calendar.startOfDay(for: date)
                return CalendarPageDayCell(
                    date: date,
                    isCurrentMonth: isCurrentMonth,
                    events: eventsByDay[dayStart] ?? []
                )
            }
        }
    }

    /// Events keyed by every calendar day they occupy (multi-day events appear
    /// on each covered day).
    private func eventsGroupedByDay() -> [Date: [UnifiedCalendarEvent]] {
        let calendar = Calendar.current
        var result: [Date: [UnifiedCalendarEvent]] = [:]
        for event in visibleCalendarEvents {
            let startDay = calendar.startOfDay(for: event.startDate)
            let endDay = calendar.startOfDay(for: event.endDate)
            var cursor = startDay
            while cursor <= endDay {
                result[cursor, default: []].append(event)
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }
        return result
    }

    private func eventsForDay(_ date: Date) -> [UnifiedCalendarEvent] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return visibleCalendarEvents
            .filter { $0.startDate < dayEnd && $0.endDate > dayStart }
            .sorted { $0.startDate < $1.startDate }
    }

    private var listSections: [CalendarPageDaySection] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var eventsByDay: [Date: [UnifiedCalendarEvent]] = [:]
        for event in visibleCalendarEvents {
            let day = calendar.startOfDay(for: event.startDate)
            eventsByDay[day, default: []].append(event)
        }

        let upcoming = eventsByDay.keys.filter { $0 >= today }.sorted()
        let past = eventsByDay.keys.filter { $0 < today }.sorted().reversed()

        var sections: [CalendarPageDaySection] = []
        for day in upcoming + past {
            let events = (eventsByDay[day] ?? []).sorted { $0.startDate < $1.startDate }
            sections.append(CalendarPageDaySection(
                date: day,
                isToday: calendar.isDate(day, inSameDayAs: today),
                title: listDayTitle(day),
                events: events
            ))
        }
        return sections
    }

    private func listDayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        if calendar.isDate(day, inSameDayAs: today) {
            return "Today"
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today), calendar.isDate(day, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.isDate(day, equalTo: today, toGranularity: .year) {
            return CalendarPageLogic.listDayFormatter.string(from: day)
        }
        return CalendarPageLogic.listDayYearFormatter.string(from: day)
    }

    private func listDayID(_ day: Date) -> String {
        "calendar-day-\(Int(day.timeIntervalSince1970))"
    }

    private func weekdayLabel(column: Int) -> String {
        let calendar = Calendar.current
        let weekday = ((calendar.firstWeekday - 1 + column) % 7) + 1
        return calendar.veryShortWeekdaySymbols[weekday - 1]
    }
}

// MARK: - Mode

private enum CalendarPageMode: String, CaseIterable, Identifiable {
    case month
    case day
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .month: return "Month"
        case .day: return "Day"
        case .list: return "List"
        }
    }
}

// MARK: - List filter

private enum CalendarListFilter: String, CaseIterable, Identifiable {
    case all
    case upcoming
    case past
    case recorded
    case unrecorded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .upcoming: return "Upcoming"
        case .past: return "Past"
        case .recorded: return "Recorded"
        case .unrecorded: return "Unrecorded"
        }
    }
}

// MARK: - Section models

private struct CalendarPageDaySection: Identifiable {
    let date: Date
    let isToday: Bool
    let title: String
    let events: [UnifiedCalendarEvent]

    var id: Date { date }
}

private struct CalendarPageDayCell {
    let date: Date?
    let isCurrentMonth: Bool
    let events: [UnifiedCalendarEvent]
}

private struct CalendarPageHourSection {
    let hour: Int
    let hourLabel: String
    let events: [UnifiedCalendarEvent]
}

// MARK: - Logic + formatters

private enum CalendarPageLogic {
    static let maxChipsPerDay = 3
    /// Fixed height per month-grid row (day number + up to 3 chips + spacing).
    static let monthRowHeight: CGFloat = 96

    static func monthStart(of date: Date) -> Date {
        let calendar = Calendar.current
        return calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    static let dayNumberFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d"
        return f
    }()

    static let monthTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    static let fullDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()

    static let listDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f
    }()

    static let listDayYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d, yyyy"
        return f
    }()

    static let startTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    static let hourLabelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h a"
        return f
    }()

    enum rangeFormatter {
        static func timeRange(for event: UnifiedCalendarEvent) -> String {
            let calendar = Calendar.current
            if event.isAllDay {
                let startDay = CalendarPageLogic.shortDateFormatter.string(from: event.startDate)
                let endDay = CalendarPageLogic.shortDateFormatter.string(from: event.endDate)
                if calendar.isDate(event.startDate, inSameDayAs: event.endDate) {
                    return "All day"
                }
                return "\(startDay) – \(endDay)"
            }
            let startTime = CalendarPageLogic.startTimeFormatter.string(from: event.startDate)
            let endTime = CalendarPageLogic.startTimeFormatter.string(from: event.endDate)
            if calendar.isDate(event.startDate, inSameDayAs: event.endDate) {
                return "\(startTime) – \(endTime)"
            }
            let startDay = CalendarPageLogic.shortDateFormatter.string(from: event.startDate)
            let endDay = CalendarPageLogic.shortDateFormatter.string(from: event.endDate)
            return "\(startDay), \(startTime) – \(endDay), \(endTime)"
        }
    }

    /// Groups a day's events into hour-of-start sections (chronological).
    static func hourSections(from events: [UnifiedCalendarEvent]) -> [CalendarPageHourSection] {
        let calendar = Calendar.current
        var grouped: [Int: [UnifiedCalendarEvent]] = [:]
        for event in events {
            let hour = calendar.component(.hour, from: event.startDate)
            grouped[hour, default: []].append(event)
        }
        return grouped.keys.sorted().map { hour in
            CalendarPageHourSection(
                hour: hour,
                hourLabel: hourLabelFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(hour) * 3600)),
                events: (grouped[hour] ?? []).sorted { $0.startDate < $1.startDate }
            )
        }
    }
}

// MARK: - Hex color helper (string variant for EKCalendarModel.colorHex)

private extension Color {
    /// Parses "rrggbb" / "#rrggbb" into a Color; nil on malformed input.
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
