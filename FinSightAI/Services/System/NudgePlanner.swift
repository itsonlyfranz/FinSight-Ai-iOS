import Foundation

struct PlannedNudge: Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let date: Date
}

/// Pure planning; delivery permission and OS limits belong to the scheduler.
enum NudgePlanner {
    static func plan(snapshot: SystemSnapshot, calendar: Calendar = .current) -> [PlannedNudge] {
        let now = snapshot.date
        let month = calendar.dateInterval(of: .month, for: now)?.start.timeIntervalSince1970 ?? 0
        var result: [PlannedNudge] = []
        for budget in snapshot.budgets where budget.limit > 0 && budget.spent >= budget.limit * Decimal(string: "0.8")! {
            let threshold = budget.spent >= budget.limit ? 100 : 80
            result.append(PlannedNudge(id: "budget-\(month)-\(budget.category.rawValue)-\(threshold)",
                title: String(localized: "\(budget.category.localizedTitle) budget at \(threshold)%"),
                body: String(localized: "Open FinSight AI to review this month's \(budget.category.localizedTitle) spending."),
                date: now.addingTimeInterval(5)))
        }
        for due in snapshot.due {
            let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: due.date) ?? due.date
            guard morning > now else { continue }
            result.append(PlannedNudge(id: "due-\(due.id)-\(calendar.startOfDay(for: due.date).timeIntervalSince1970)",
                title: String(localized: "Recurring expense due"), body: String(localized: "\(due.merchant) is expected today."), date: morning))
        }
        var monday = DateComponents()
        monday.weekday = 2
        monday.hour = 9
        monday.minute = 0
        if let digest = calendar.nextDate(after: now, matching: monday, matchingPolicy: .nextTime) {
            let count = snapshot.insights.count
            let body = count == 0 ? String(localized: "Open FinSight AI to see this week's spending.")
                : String(localized: "\(count) insights are waiting in FinSight AI.")
            result.append(PlannedNudge(id: "digest-\(digest.timeIntervalSince1970)", title: String(localized: "Your weekly digest is ready"),
                body: body, date: digest))
        }
        return Array(result.sorted { $0.date < $1.date }.prefix(60))
    }
}
