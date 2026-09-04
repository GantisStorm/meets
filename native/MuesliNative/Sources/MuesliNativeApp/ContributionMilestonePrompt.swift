import Foundation

enum ContributionMilestoneAction: String, CaseIterable {
    case githubStar = "github_star"
    case buyMeCoffee = "buy_me_coffee"

    var supportURL: URL? {
        switch self {
        case .githubStar:
            return URL(string: "https://github.com/Muesli-HQ/muesli")!
        case .buyMeCoffee:
            return URL(string: "https://buymeacoffee.com/phequals7")!
        }
    }
}

enum ContributionMilestoneKind: String {
    case meetings
}

struct ContributionMilestonePrompt: Equatable, Identifiable {
    let kind: ContributionMilestoneKind
    let count: Int
    let showGitHubStar: Bool
    let showBuyMeCoffee: Bool

    var id: String { "\(kind.rawValue):\(count)" }

    var title: String {
        "You captured \(ContributionMilestonePolicy.formatCount(count)) meetings!"
    }

    var message: String {
        "That is a lot of conversations turned into something useful. If Muesli has been keeping your meetings in order, a GitHub star or a coffee helps keep it moving."
    }
}

enum ContributionMilestonePolicy {
    static let meetingInterval = 25

    /// Grouping locale for milestone counts. Interpolated into fixed English
    /// copy, so the separator must not follow `Locale.current`: a locale-grouped
    /// "31.000" reads as thirty-one point zero in an English sentence.
    /// Deliberately `en_US` and not `en_US_POSIX` — the POSIX locale drops
    /// grouping entirely and formats 31000 as "31000".
    static let countGroupingLocale = Locale(identifier: "en_US")

    static func formatCount(_ value: Int) -> String {
        formatCount(value, locale: countGroupingLocale)
    }

    static func formatCount(_ value: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func nextMilestone(after totalMeetings: Int) -> Int {
        nextMilestone(after: totalMeetings, interval: meetingInterval)
    }

    private static func nextMilestone(after total: Int, interval: Int) -> Int {
        let clampedTotal = max(total, 0)
        return ((clampedTotal / interval) + 1) * interval
    }

    static func resolvedNextMilestone(
        storedNextMilestone: Int?,
        totalMeetings: Int,
        githubStarClicked: Bool,
        buyMeCoffeeClicked: Bool
    ) -> Int? {
        let isComplete = githubStarClicked && buyMeCoffeeClicked
        guard !isComplete else { return nil }
        guard let storedNextMilestone else {
            return nextMilestone(after: totalMeetings)
        }
        guard totalMeetings >= storedNextMilestone + meetingInterval else { return storedNextMilestone }
        return nextMilestone(after: totalMeetings)
    }

    static func prompt(
        totalMeetings: Int,
        nextMilestone: Int?,
        githubStarClicked: Bool,
        buyMeCoffeeClicked: Bool,
        dismissedThisLaunch: Bool
    ) -> ContributionMilestonePrompt? {
        guard !dismissedThisLaunch,
              let nextMilestone,
              totalMeetings >= nextMilestone else {
            return nil
        }

        let showGitHubStar = !githubStarClicked
        let showBuyMeCoffee = !buyMeCoffeeClicked
        guard showGitHubStar || showBuyMeCoffee else {
            return nil
        }

        return ContributionMilestonePrompt(
            kind: .meetings,
            count: nextMilestone,
            showGitHubStar: showGitHubStar,
            showBuyMeCoffee: showBuyMeCoffee
        )
    }
}
