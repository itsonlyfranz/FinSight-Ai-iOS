import Foundation

extension DateInterval {
    /// Half-open containment (`start <= date < end`). `DateInterval.contains` includes `end`, which
    /// would count midnight on the 1st of the next month in this month.
    func containsExcludingEnd(_ date: Date) -> Bool { date >= start && date < end }
}

// MARK: - Income gauge

/// "% of income spent / buffer remaining" for one month. All amounts are exact `Decimal`s.
struct IncomeGauge: Equatable, Sendable {
    let income: Decimal
    let spent: Decimal

    static let empty = IncomeGauge(income: 0, spent: 0)

    var hasIncome: Bool { income > 0 }

    /// Share of income spent, uncapped (1.25 = 125%). Zero when there is no income.
    var fractionSpent: Double {
        guard income > 0 else { return 0 }
        return (spent / income).doubleValue
    }

    /// `fractionSpent` limited to 0…1 for gauge and progress views.
    var gaugeValue: Double { min(1, max(0, fractionSpent)) }

    /// Income minus spending; negative when overspent.
    var buffer: Decimal { income - spent }

    var isOverspent: Bool { hasIncome && spent > income }
}

enum IncomeCalculator {
    /// Recurring monthly income: the sum of the active income sources.
    static func recurringMonthlyIncome(sources: [IncomeSource]) -> Decimal {
        sources.filter(\.isActive).map(\.monthlyAmount).sum()
    }

    /// Income for the month containing `month`: recurring sources plus income-kind transactions
    /// logged inside that month (one-off income such as a bonus).
    static func monthlyIncome(
        sources: [IncomeSource],
        transactions: [TransactionRecord],
        month: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        let interval = calendar.dateInterval(of: .month, for: month) ?? DateInterval(start: month, end: month)
        let logged = transactions
            .filter { $0.countsAsIncome && interval.containsExcludingEnd($0.date) }
            .map(\.amount)
            .sum()
        return recurringMonthlyIncome(sources: sources) + logged
    }

    static func spending(
        in transactions: [TransactionRecord],
        month: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        let interval = calendar.dateInterval(of: .month, for: month) ?? DateInterval(start: month, end: month)
        return transactions
            .filter { $0.countsAsSpending && interval.containsExcludingEnd($0.date) }
            .map(\.amount)
            .sum()
    }

    static func gauge(
        sources: [IncomeSource],
        transactions: [TransactionRecord],
        month: Date,
        calendar: Calendar = .current
    ) -> IncomeGauge {
        IncomeGauge(
            income: monthlyIncome(sources: sources, transactions: transactions, month: month, calendar: calendar),
            spent: spending(in: transactions, month: month, calendar: calendar)
        )
    }
}

// MARK: - Budgets

enum BudgetStatus: String, Equatable, Sendable {
    case onTrack
    case nearLimit
    case overBudget

    var title: String {
        switch self {
        case .onTrack: "On track"
        case .nearLimit: "Near limit"
        case .overBudget: "Over budget"
        }
    }

    var systemImage: String {
        switch self {
        case .onTrack: "checkmark.circle.fill"
        case .nearLimit: "exclamationmark.circle.fill"
        case .overBudget: "xmark.octagon.fill"
        }
    }
}

/// One category's budget measured against the month's spending.
struct BudgetProgress: Identifiable, Equatable, Sendable {
    /// Fraction of the limit at which a budget is flagged as `nearLimit`.
    static let nearLimitThreshold = 0.8

    let category: SpendingCategory
    /// The configured monthly amount.
    let baseLimit: Decimal
    /// Unspent budget carried in from earlier months (zero unless rollover is enabled).
    let carriedOver: Decimal
    let spent: Decimal

    var id: SpendingCategory { category }

    /// What can be spent this month: the base amount plus any carry-over.
    var limit: Decimal { baseLimit + carriedOver }

    var remaining: Decimal { limit - spent }

    /// Spent ÷ limit, uncapped. A zero limit with any spending counts as fully used.
    var fractionUsed: Double {
        guard limit > 0 else { return spent > 0 ? 1 : 0 }
        return (spent / limit).doubleValue
    }

    /// `fractionUsed` limited to 0…1 for progress views.
    var progressValue: Double { min(1, max(0, fractionUsed)) }

    var status: BudgetStatus {
        if spent > limit { return .overBudget }
        if fractionUsed >= Self.nearLimitThreshold { return .nearLimit }
        return .onTrack
    }
}

enum BudgetCalculator {
    /// Longest rollover chain considered, so a budget created years ago stays cheap to evaluate.
    static let maximumRolloverMonths = 12

    static func progress(
        budgets: [Budget],
        transactions: [TransactionRecord],
        month: Date,
        calendar: Calendar = .current
    ) -> [BudgetProgress] {
        let spendingByCategory = Dictionary(
            grouping: transactions.filter(\.countsAsSpending),
            by: \.category
        )
        let interval = calendar.dateInterval(of: .month, for: month) ?? DateInterval(start: month, end: month)

        return budgets
            .filter { $0.category.countsAsSpending }
            .map { budget in
                let entries = spendingByCategory[budget.category] ?? []
                let spent = entries.filter { interval.containsExcludingEnd($0.date) }.map(\.amount).sum()
                let carried = budget.rolloverEnabled
                    ? carryOver(for: budget, entries: entries, before: interval.start, calendar: calendar)
                    : 0
                return BudgetProgress(
                    category: budget.category,
                    baseLimit: budget.monthlyAmount,
                    carriedOver: carried,
                    spent: spent
                )
            }
            .sorted { lhs, rhs in
                if lhs.fractionUsed != rhs.fractionUsed { return lhs.fractionUsed > rhs.fractionUsed }
                return lhs.category.title < rhs.category.title
            }
    }

    /// Unspent budget from each full month between the budget's creation month and `monthStart`.
    /// Overspending in a month never produces a negative carry-over.
    static func carryOver(
        for budget: Budget,
        entries: [TransactionRecord],
        before monthStart: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        guard var cursor = calendar.dateInterval(of: .month, for: budget.createdAt)?.start else { return 0 }
        var months: [DateInterval] = []
        while cursor < monthStart, months.count < maximumRolloverMonths {
            guard let interval = calendar.dateInterval(of: .month, for: cursor) else { break }
            months.append(interval)
            cursor = interval.end
        }
        let recent = months.suffix(maximumRolloverMonths)
        return recent.map { interval in
            let spent = entries.filter { interval.containsExcludingEnd($0.date) }.map(\.amount).sum()
            return max(0, budget.monthlyAmount - spent)
        }.sum()
    }

    static func totalLimit(_ items: [BudgetProgress]) -> Decimal { items.map(\.limit).sum() }
    static func totalSpent(_ items: [BudgetProgress]) -> Decimal { items.map(\.spent).sum() }
}

// MARK: - Savings goals

/// Where a goal stands and when it will be funded at the current pace.
struct GoalProjection: Equatable, Sendable {
    enum Outlook: Equatable, Sendable {
        case reached
        /// No saving pace to project from.
        case noPace
        case onPace(monthsToReach: Int, fundedBy: Date)
    }

    let remaining: Decimal
    let monthlyPace: Decimal
    let outlook: Outlook
    /// Monthly amount needed to hit the goal's target date; nil without a (future) target date.
    let requiredMonthly: Decimal?

    var monthsToReach: Int? {
        if case .onPace(let months, _) = outlook { return months }
        return nil
    }

    var fundedBy: Date? {
        if case .onPace(_, let date) = outlook { return date }
        return nil
    }

    /// True when a target date exists and the current pace would miss it.
    func isBehindTargetDate(_ targetDate: Date?) -> Bool {
        guard let targetDate, let fundedBy else { return false }
        return fundedBy > targetDate
    }
}

enum GoalCalculator {
    /// Window of recent contributions used to estimate a goal's own saving pace.
    static let paceWindowMonths = 3

    /// Whole months needed to save `remaining` at `monthlyPace`, rounding up. Zero when nothing is
    /// left to save; nil when there is no positive pace.
    static func monthsToReach(remaining: Decimal, monthlyPace: Decimal) -> Int? {
        guard remaining > 0 else { return 0 }
        guard monthlyPace > 0 else { return nil }
        var quotient = remaining / monthlyPace
        var rounded = Decimal()
        NSDecimalRound(&rounded, &quotient, 0, .up)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    static func projection(
        for goal: SavingsGoal,
        monthlyPace: Decimal,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> GoalProjection {
        projection(
            target: goal.targetAmount,
            saved: goal.savedAmount,
            targetDate: goal.targetDate,
            monthlyPace: monthlyPace,
            now: now,
            calendar: calendar
        )
    }

    static func projection(
        target: Decimal,
        saved: Decimal,
        targetDate: Date?,
        monthlyPace: Decimal,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> GoalProjection {
        let remaining = max(0, target - saved)
        let required = requiredMonthly(remaining: remaining, targetDate: targetDate, now: now, calendar: calendar)
        guard target > 0, remaining > 0 else {
            return GoalProjection(remaining: remaining, monthlyPace: monthlyPace, outlook: .reached, requiredMonthly: required)
        }
        guard let months = monthsToReach(remaining: remaining, monthlyPace: monthlyPace),
              let fundedBy = calendar.date(byAdding: .month, value: months, to: now) else {
            return GoalProjection(remaining: remaining, monthlyPace: monthlyPace, outlook: .noPace, requiredMonthly: required)
        }
        return GoalProjection(
            remaining: remaining,
            monthlyPace: monthlyPace,
            outlook: .onPace(monthsToReach: months, fundedBy: fundedBy),
            requiredMonthly: required
        )
    }

    /// What must be saved each month to finish by `targetDate`, counting part months as whole ones.
    static func requiredMonthly(
        remaining: Decimal,
        targetDate: Date?,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Decimal? {
        guard remaining > 0, let targetDate, targetDate > now else { return nil }
        let components = calendar.dateComponents([.month, .day], from: now, to: targetDate)
        let months = max(1, (components.month ?? 0) + ((components.day ?? 0) > 0 ? 1 : 0))
        return remaining / Decimal(months)
    }

    /// The goal's own pace from net contributions over the recent window; nil when it has none.
    static func ownPace(
        for goal: SavingsGoal,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Decimal? {
        guard let windowStart = calendar.date(byAdding: .month, value: -paceWindowMonths, to: now) else { return nil }
        let recent = (goal.contributions ?? []).filter { $0.date >= windowStart && $0.date <= now }
        guard !recent.isEmpty else { return nil }
        let net = recent.map(\.amount).sum()
        return net > 0 ? net / Decimal(paceWindowMonths) : nil
    }

    /// Monthly amount left over after spending, shared equally between the unfinished goals.
    static func surplusShare(monthlyIncome: Decimal, monthlySpending: Decimal, unfinishedGoals: Int) -> Decimal {
        guard unfinishedGoals > 0 else { return 0 }
        let surplus = max(0, monthlyIncome - monthlySpending)
        return surplus / Decimal(unfinishedGoals)
    }

    /// Pace used for projections: the goal's recent contributions when it has any, otherwise its
    /// share of the monthly surplus.
    static func pace(
        for goal: SavingsGoal,
        surplusShare: Decimal,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Decimal {
        ownPace(for: goal, now: now, calendar: calendar) ?? surplusShare
    }
}

// MARK: - Transaction filtering

/// Category chips plus merchant search.
struct TransactionFilter: Equatable, Sendable {
    var categories: Set<SpendingCategory> = []
    var searchText = ""

    var isActive: Bool { !categories.isEmpty || !trimmedSearch.isEmpty }

    private var trimmedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func toggle(_ category: SpendingCategory) {
        if categories.contains(category) {
            categories.remove(category)
        } else {
            categories.insert(category)
        }
    }

    mutating func reset() {
        categories = []
        searchText = ""
    }

    func matches(_ transaction: TransactionRecord) -> Bool {
        if !categories.isEmpty, !categories.contains(transaction.category) { return false }
        let query = trimmedSearch
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return transaction.merchantName.range(of: query, options: options) != nil
            || transaction.note.range(of: query, options: options) != nil
    }

    func apply(to transactions: [TransactionRecord]) -> [TransactionRecord] {
        isActive ? transactions.filter(matches) : transactions
    }
}
