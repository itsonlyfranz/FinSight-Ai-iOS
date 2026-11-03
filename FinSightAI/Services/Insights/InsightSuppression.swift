import Foundation

/// A dismissed or snoozed insight, as persisted in `InsightStateRecord`.
struct InsightSuppression: Equatable, Sendable {
    enum Status: String, Sendable {
        case dismissed
        case snoozed
    }

    let insightID: String
    let status: Status
    /// When a snooze ends. Ignored for dismissals.
    let until: Date?
}

enum InsightVisibility {
    /// `insights` without the ones the user dismissed, or snoozed and whose snooze hasn't ended.
    ///
    /// Insight ids embed their period, so a dismissal only hides that period's finding: the same
    /// kind of insight can come back next month.
    static func visible(_ insights: [Insight], suppressions: [InsightSuppression], now: Date) -> [Insight] {
        let hidden = Set(suppressions.filter { isActive($0, now: now) }.map(\.insightID))
        return insights.filter { !hidden.contains($0.id) }
    }

    static func isActive(_ suppression: InsightSuppression, now: Date) -> Bool {
        switch suppression.status {
        case .dismissed: true
        case .snoozed: (suppression.until ?? .distantPast) > now
        }
    }
}
