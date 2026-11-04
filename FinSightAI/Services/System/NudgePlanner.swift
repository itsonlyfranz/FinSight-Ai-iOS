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
            let finding = snapshot.insights.first { $0.category == budget.category && $0.kind == .budgetBreach }
            result.append(PlannedNudge(id: "budget-\(month)-\(budget.category.rawValue)-\(threshold)",
                title: "\(budget.category.title) budget at \(threshold)%",
                body: finding?.summary ?? "You've spent \(budget.spent.formatted(.currency(code: snapshot.currency))) of \(budget.limit.formatted(.currency(code: snapshot.currency))).",
                date: now.addingTimeInterval(5)))
        }
        for due in snapshot.due {
            let morning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: due.date) ?? due.date
            guard morning > now else { continue }
            result.append(PlannedNudge(id: "due-\(due.id)-\(calendar.startOfDay(for: due.date).timeIntervalSince1970)",
                title: "Recurring expense due", body: "\(due.merchant) is expected today.", date: morning))
        }
        var monday = DateComponents()
        monday.weekday = 2
        monday.hour = 9
        monday.minute = 0
        if let digest = calendar.nextDate(after: now, matching: monday, matchingPolicy: .nextTime) {
            let detail = snapshot.insights.first.map { " \($0.title): \($0.summary)" } ?? ""
            result.append(PlannedNudge(id: "digest-\(digest.timeIntervalSince1970)", title: "Your weekly FinSight digest",
                body: "This month so far: \(snapshot.spendText).\(detail)", date: digest))
        }
        return Array(result.sorted { $0.date < $1.date }.prefix(60))
    }
}
