import Foundation

struct MarketingVersion: Comparable, Equatable {
    let components: [Int]

    init?(_ value: String) {
        let numericPrefix = value.split(separator: "-", maxSplits: 1).first ?? Substring(value)
        let parts = numericPrefix.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        var parsedComponents: [Int] = []
        parsedComponents.reserveCapacity(parts.count)
        for part in parts {
            guard let component = Int(part) else { return nil }
            parsedComponents.append(component)
        }
        components = parsedComponents
    }

    static func == (lhs: MarketingVersion, rhs: MarketingVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: MarketingVersion, rhs: MarketingVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

enum FeatureTourTarget: String, Hashable {
    case quillSettings
    case dictationProviderSetting
    case parakeetFamilyCard
    case appleSpeechCard
    case meetingPeople
    case modelLibrary
    case dictionarySuggestions
    case meetingsSidebar
    case liveCaptionsSetting
    case cloudCleanupSetting
    case streamingModels
    case experimentalModels

    var navigationRoute: FeatureTourNavigationRoute {
        switch self {
        case .quillSettings, .dictationProviderSetting, .cloudCleanupSetting:
            // Retained only while their removed-feature settings rows are still
            // being stripped centrally; the empty catalog never routes to them.
            return .settings(.general)
        case .liveCaptionsSetting:
            return .settings(.meetings)
        case .dictionarySuggestions:
            return .tab(.dictionary)
        case .meetingsSidebar:
            return .meetingsBrowser
        case .meetingPeople:
            return .meetingPeople
        case .modelLibrary, .appleSpeechCard, .parakeetFamilyCard, .experimentalModels:
            return .models(.transcription)
        case .streamingModels:
            return .models(.streaming)
        }
    }

    var modelsCategory: ModelsCategory? {
        guard case let .models(category) = navigationRoute else { return nil }
        return category
    }
}

enum FeatureTourNavigationRoute: Equatable {
    case settings(SettingsPane)
    case tab(DashboardTab)
    case models(ModelsCategory)
    case meetingsBrowser
    case meetingPeople
}

struct FeatureTourStep: Identifiable, Equatable {
    let id: String
    let eyebrow: String
    let title: String
    let message: String
    let systemImage: String
    let target: FeatureTourTarget?
}

struct FeatureTour: Equatable {
    let version: String
    let steps: [FeatureTourStep]

    var displayVersion: String {
        guard let marketingVersion = MarketingVersion(version) else { return version }
        var components = marketingVersion.components
        while components.count > 2, components.last == 0 {
            components.removeLast()
        }
        return components.map(String.init).joined(separator: ".")
    }
}

extension AppState {
    var activeFeatureTourTarget: FeatureTourTarget? {
        guard let activeFeatureTour,
              activeFeatureTour.steps.indices.contains(featureTourStepIndex) else { return nil }
        return activeFeatureTour.steps[featureTourStepIndex].target
    }
}

enum FeatureTourCatalog {
    /// The app is meetings-only; the remaining FeatureTourTarget cases are
    /// kept alive only for views the central pass still references. No
    /// meetings-only tour steps exist yet, so the catalog is empty and no
    /// automatic/manual tour is offered.
    static var latest: FeatureTour {
        FeatureTour(version: "0.8.4", steps: [])
    }
}

enum FeatureTourPresentationPolicy {
    static func shouldPresentAutomatically(
        currentVersion: String,
        previousVersion: String?,
        lastPresentedTourVersion: String?,
        hasCompletedOnboarding: Bool,
        tour: FeatureTour
    ) -> Bool {
        guard hasCompletedOnboarding,
              let current = MarketingVersion(currentVersion),
              let target = MarketingVersion(tour.version),
              current >= target else {
            return false
        }

        let lastPresented = lastPresentedTourVersion.flatMap(MarketingVersion.init)
        if let lastPresented, lastPresented >= target {
            return false
        }

        guard let previousVersion else {
            // A completed onboarding with no version marker identifies an
            // existing install rather than a fresh install.
            return true
        }
        guard let previous = MarketingVersion(previousVersion) else { return true }
        if previous < target {
            return true
        }

        // Prerelease builds can share a marketing version even when a newer
        // walkthrough first ships between those builds. A prior tour marker
        // distinguishes that upgrade from a fresh install at the same version.
        return previous == target && lastPresented != nil
    }
}

final class FeatureTourStore {
    private enum Key {
        static let lastLaunchedVersion = "featureTour.lastLaunchedVersion"
        static let lastPresentedVersion = "featureTour.lastPresentedVersion"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func automaticTour(
        currentVersion: String,
        hasCompletedOnboarding: Bool,
        canPresent: Bool,
        tour: FeatureTour = FeatureTourCatalog.latest
    ) -> FeatureTour? {
        if !hasCompletedOnboarding {
            defaults.set(currentVersion, forKey: Key.lastLaunchedVersion)
            return nil
        }

        // Permission-repair onboarding owns the foreground. Leave the previous
        // version untouched so the tour remains eligible on the next healthy launch.
        guard canPresent else { return nil }

        let shouldPresent = FeatureTourPresentationPolicy.shouldPresentAutomatically(
            currentVersion: currentVersion,
            previousVersion: defaults.string(forKey: Key.lastLaunchedVersion),
            lastPresentedTourVersion: defaults.string(forKey: Key.lastPresentedVersion),
            hasCompletedOnboarding: true,
            tour: tour
        )
        defaults.set(currentVersion, forKey: Key.lastLaunchedVersion)
        return shouldPresent ? tour : nil
    }

    func markOffered(_ tour: FeatureTour) {
        defaults.set(tour.version, forKey: Key.lastPresentedVersion)
    }
}
