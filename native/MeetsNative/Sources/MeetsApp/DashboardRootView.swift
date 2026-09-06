import SwiftUI
import MeetsCore

enum DashboardWindowLayout {
    /// Narrow enough to sit beside a call window while preserving a useful
    /// notes editor when the sidebar is collapsed or hidden.
    static let minimumContentWidth: CGFloat = 520
    static let minimumContentHeight: CGFloat = 600
    static let compactQuickNotesThreshold: CGFloat = 600

    static func usesCompactQuickNotes(width: CGFloat, hasOpenMeeting: Bool) -> Bool {
        hasOpenMeeting && width < compactQuickNotesThreshold
    }
}

private struct CompactQuickNotesEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var usesCompactQuickNotes: Bool {
        get { self[CompactQuickNotesEnvironmentKey.self] }
        set { self[CompactQuickNotesEnvironmentKey.self] = newValue }
    }
}

@Observable
final class DashboardSidebarPresentation {
    var isCollapsed = false

    func toggle() {
        isCollapsed.toggle()
    }
}

struct DashboardContentLayout<SidebarContent: View, DetailContent: View>: View {
    let usesCompactQuickNotes: Bool
    @ViewBuilder let sidebar: () -> SidebarContent
    @ViewBuilder let detail: () -> DetailContent

    var body: some View {
        HSplitView {
            if !usesCompactQuickNotes {
                sidebar()
            }

            detail()
                .environment(\.usesCompactQuickNotes, usesCompactQuickNotes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MeetsTheme.backgroundBase)
        }
    }
}

struct DashboardRootView: View {
    let appState: AppState
    let controller: MeetsController
    @State private var sidebarPresentation: DashboardSidebarPresentation

    init(
        appState: AppState,
        controller: MeetsController,
        sidebarPresentation: DashboardSidebarPresentation = DashboardSidebarPresentation()
    ) {
        self.appState = appState
        self.controller = controller
        _sidebarPresentation = State(initialValue: sidebarPresentation)
    }

    var sidebarView: SidebarView {
        SidebarView(
            appState: appState,
            controller: controller,
            isCollapsed: sidebarPresentation.isCollapsed,
            onToggleCollapsed: {
                withAnimation(.easeInOut(duration: 0.22)) {
                    sidebarPresentation.toggle()
                }
            }
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let usesCompactQuickNotes = DashboardWindowLayout.usesCompactQuickNotes(
                width: proxy.size.width,
                hasOpenMeeting: hasOpenMeeting
            )

            DashboardContentLayout(usesCompactQuickNotes: usesCompactQuickNotes) {
                sidebarView
                .frame(
                    minWidth: sidebarPresentation.isCollapsed ? 68 : 240,
                    idealWidth: sidebarPresentation.isCollapsed ? 68 : 260,
                    maxWidth: sidebarPresentation.isCollapsed ? 68 : 300
                )
            } detail: {
                detailContent
            }
        }
        .frame(
            minWidth: DashboardWindowLayout.minimumContentWidth,
            minHeight: DashboardWindowLayout.minimumContentHeight
        )
        .preferredColorScheme(appState.config.darkMode ? .dark : .light)
        .alert(
            appState.contributionMilestonePrompt?.title ?? "Meets milestone",
            isPresented: Binding(
                get: { appState.contributionMilestonePrompt != nil },
                set: { if !$0 { controller.dismissContributionMilestonePrompt() } }
            )
        ) {
            if appState.contributionMilestonePrompt?.showGitHubStar == true {
                Button("Star on GitHub") {
                    controller.openContributionMilestoneAction(.githubStar)
                }
            }
            if appState.contributionMilestonePrompt?.showBuyMeCoffee == true {
                Button("Buy Me a Coffee") {
                    controller.openContributionMilestoneAction(.buyMeCoffee)
                }
            }
            Button("Later", role: .cancel) {
                controller.dismissContributionMilestonePrompt()
            }
        } message: {
            Text(appState.contributionMilestonePrompt?.message ?? "")
        }
        .onAppear {
            controller.recordContributionMilestonePromptSeen()
        }
        .onChange(of: appState.contributionMilestonePrompt?.id) { _, _ in
            controller.recordContributionMilestonePromptSeen()
        }
        .sheet(
            item: Binding<DiagnosticIncident?>(
                get: { appState.pendingDiagnosticIncident },
                set: { if $0 == nil { controller.dismissDiagnosticIncidentPrompt() } }
            )
        ) { incident in
            DiagnosticIncidentReportView(
                incident: incident,
                onOpenIssue: { controller.openDiagnosticIncidentIssue(incident) },
                onDismiss: { controller.dismissDiagnosticIncidentPrompt() }
            )
        }
        .sheet(
            isPresented: Binding(
                get: { appState.isMeetingTemplatesManagerPresented },
                set: { appState.isMeetingTemplatesManagerPresented = $0 }
            )
        ) {
            MeetingTemplatesManagerView(
                appState: appState,
                controller: controller,
                onClose: { appState.isMeetingTemplatesManagerPresented = false }
            )
        }
    }

    private var hasOpenMeeting: Bool {
        if case .document = appState.meetingsNavigationState {
            return true
        }
        return false
    }

    @ViewBuilder
    private var detailContent: some View {
        if appState.isSearchActive,
           case .document(let id) = appState.meetingsNavigationState {
            MeetingDetailView(
                meeting: appState.selectedMeeting,
                controller: controller,
                appState: appState,
                onBack: {
                    appState.meetingsNavigationState = .browser
                    appState.selectedMeetingID = nil
                    appState.selectedMeetingRecord = nil
                },
                backLabel: "Back to Search"
            )
            .id(id)
        } else if appState.isSearchActive {
            SearchResultsView(appState: appState, controller: controller)
        } else {
            switch appState.selectedTab {
            case .calendar:
                CalendarPageView(appState: appState, controller: controller)
            case .insights:
                InsightsView(
                    initialSection: appState.insightsInitialSection,
                    loadSnapshot: { range in try await controller.insightsSnapshot(range: range) },
                    onBack: { controller.closeInsights() },
                    backLabel: appState.insightsBackLabel,
                    onOpenCalendar: { filter in controller.openCalendarWithFilter(filter) }
                )
            case .meetings:
                MeetingsView(appState: appState, controller: controller)
            case .dictionary:
                DictionaryView(appState: appState, controller: controller)
            case .models:
                ModelsView(appState: appState, controller: controller)
            case .settings:
                SettingsView(appState: appState, controller: controller)
            case .about:
                AboutView(appState: appState)
            }
        }
    }
}
