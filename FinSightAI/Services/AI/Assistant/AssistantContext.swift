import Foundation

/// Everything "Ask FinSight" knows about the user's money, captured once per question.
///
/// Built from the same in-memory data the dashboard and insights use, so the assistant's answers
/// agree with the rest of the app. Both the deterministic quick answers and the model's tools read it.
struct AssistantContext: Sendable {
    /// A recurring charge the user set up.
    struct RecurringCharge: Equatable, Sendable {
        let merchant: String
        let category: SpendingCategory
        let monthlyAmount: Decimal
        let expectedDate: Date
        /// Expected later this month, so not paid yet.
        let isUpcoming: Bool
    }

    /// One savings goal's progress.
    struct GoalLine: Equatable, Sendable {
        let name: String
        let saved: Decimal
        let target: Decimal

        var fractionSaved: Double {
            guard target > 0 else { return 0 }
            return min(1, (saved / target).doubleValue)
        }
    }

    let ledger: LedgerSnapshot
    let summary: MonthlySummary
    /// Engine insights still showing, most important first.
    let insights: [Insight]
    /// This month's income: recurring sources plus income logged this month.
    let monthlyIncome: Decimal
    let recurringCharges: [RecurringCharge]
    let goals: [GoalLine]
    let profile: UserProfile

    init(
        ledger: LedgerSnapshot,
        summary: MonthlySummary,
        insights: [Insight] = [],
        monthlyIncome: Decimal = 0,
        recurringCharges: [RecurringCharge] = [],
        goals: [GoalLine] = [],
        profile: UserProfile = UserProfile()
    ) {
        self.ledger = ledger
        self.summary = summary
        self.insights = insights
        self.monthlyIncome = monthlyIncome
        self.recurringCharges = recurringCharges
        self.goals = goals
        self.profile = profile
    }

    var now: Date { ledger.now }
    var calendar: Calendar { ledger.calendar }

    /// Whether there is anything to answer from.
    var hasData: Bool { !ledger.entries.isEmpty || !recurringCharges.isEmpty }

    /// Recurring charges still expected this month.
    var upcomingRecurringTotal: Decimal {
        recurringCharges.filter(\.isUpcoming).map(\.monthlyAmount).sum()
    }
}

// MARK: - Calculations

/// Whether an amount fits in what is left of this month's income.
struct AffordabilityCheck: Equatable, Sendable {
    enum Verdict: String, Sendable {
        /// Fits, with at least a tenth of the month's income left over.
        case comfortable
        /// Fits, but leaves less than a tenth of the month's income.
        case tight
        /// More than what is left this month.
        case short
        /// No income is recorded, so there is nothing to measure against.
        case noIncome
    }

    let amount: Decimal
    let income: Decimal
    let spent: Decimal
    /// Recurring charges still expected later this month.
    let upcomingRecurring: Decimal

    /// What is left of this month's income before the purchase.
    var leftBefore: Decimal { income - spent - upcomingRecurring }
    var leftAfter: Decimal { leftBefore - amount }
    /// How much more than what is left the amount is (zero when it fits).
    var shortfall: Decimal { max(0, -leftAfter) }

    var verdict: Verdict {
        guard income > 0 else { return .noIncome }
        if leftAfter < 0 { return .short }
        return leftAfter < income / 10 ? .tight : .comfortable
    }

    static func make(amount: Decimal, context: AssistantContext) -> AffordabilityCheck {
        AffordabilityCheck(
            amount: amount,
            income: context.monthlyIncome,
            spent: context.ledger.totalSpending(monthsAgo: 0),
            upcomingRecurring: context.upcomingRecurringTotal
        )
    }
}

/// One month's spending against the month before it, for "Why was March so high?".
struct MonthReview: Equatable, Sendable {
    struct CategoryChange: Equatable, Sendable {
        let category: SpendingCategory
        let total: Decimal
        let previous: Decimal
        var change: Decimal { total - previous }
    }

    static let maximumChanges = 3
    static let maximumPurchases = 3

    let monthsAgo: Int
    let monthStart: Date
    let previousMonthStart: Date
    let total: Decimal
    let previousTotal: Decimal
    /// Categories that moved, biggest increase first, then biggest decrease.
    let changes: [CategoryChange]
    /// The month's largest single expenses, largest first.
    let largestPurchases: [LedgerEntry]

    var change: Decimal { total - previousTotal }
    var increases: [CategoryChange] { changes.filter { $0.change > 0 } }

    static func make(monthsAgo: Int, ledger: LedgerSnapshot) -> MonthReview {
        let month = min(max(0, monthsAgo), 11)
        let current = Dictionary(uniqueKeysWithValues: ledger.categoryTotals(monthsAgo: month).map { ($0.category, $0.total) })
        let previous = Dictionary(uniqueKeysWithValues: ledger.categoryTotals(monthsAgo: month + 1).map { ($0.category, $0.total) })
        let changes = Set(current.keys).union(previous.keys)
            .map { CategoryChange(category: $0, total: current[$0] ?? 0, previous: previous[$0] ?? 0) }
            .filter { $0.change != 0 }
            .sorted { lhs, rhs in
                if (lhs.change > 0) != (rhs.change > 0) { return lhs.change > 0 }
                let lhsSize = abs(lhs.change), rhsSize = abs(rhs.change)
                return lhsSize != rhsSize ? lhsSize > rhsSize : lhs.category.rawValue < rhs.category.rawValue
            }
        let purchases = ledger.entries(monthsAgo: month)
            .filter(\.countsAsSpending)
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.date < $1.date }
        return MonthReview(
            monthsAgo: month,
            monthStart: ledger.monthStart(monthsAgo: month),
            previousMonthStart: ledger.monthStart(monthsAgo: month + 1),
            total: current.values.sum(),
            previousTotal: previous.values.sum(),
            changes: Array(changes.prefix(maximumChanges * 2)),
            largestPurchases: Array(purchases.prefix(maximumPurchases))
        )
    }
}

// MARK: - Plain text for the model

/// What the assistant's extra tools hand back to the model. English, with amounts formatted by code
/// in the user's currency, like `LedgerText`.
enum AssistantText {
    static func monthReview(_ review: MonthReview) -> String {
        let label = MonthFormatter.label(for: review.monthStart)
        let previousLabel = MonthFormatter.label(for: review.previousMonthStart)
        guard review.total > 0 || review.previousTotal > 0 else {
            return "No spending in \(label) or \(previousLabel)."
        }
        let direction = review.change >= 0 ? "more" : "less"
        var lines = [
            "\(label): spent \(LedgerText.money(review.total)). \(previousLabel): spent \(LedgerText.money(review.previousTotal)).",
            "Difference: \(LedgerText.money(abs(review.change))) \(direction) than \(previousLabel)."
        ]
        if !review.changes.isEmpty {
            lines.append("Category changes against \(previousLabel):")
            lines += review.changes.map {
                "- \($0.category.title): \(LedgerText.money($0.total)) vs \(LedgerText.money($0.previous)) (\($0.change >= 0 ? "up" : "down") \(LedgerText.money(abs($0.change))))"
            }
        }
        if !review.largestPurchases.isEmpty {
            lines.append("Largest purchases in \(label):")
            lines += review.largestPurchases.map {
                "- \($0.merchant.isEmpty ? $0.category.title : $0.merchant) (\($0.category.title)): \(LedgerText.money($0.amount))"
            }
        }
        return lines.joined(separator: "\n")
    }

    static func affordability(_ check: AffordabilityCheck) -> String {
        guard check.verdict != .noIncome else {
            return "No income is recorded for this month, so affordability can't be checked. Spent so far this month: \(LedgerText.money(check.spent))."
        }
        let verdict: String = switch check.verdict {
        case .comfortable: "It fits comfortably."
        case .tight: "It fits, but leaves little for the rest of the month."
        case .short: "It does not fit: it is \(LedgerText.money(check.shortfall)) more than what is left."
        case .noIncome: ""
        }
        return [
            "Amount asked about: \(LedgerText.money(check.amount)).",
            "This month's income: \(LedgerText.money(check.income)). Spent so far: \(LedgerText.money(check.spent)). Recurring charges still due this month: \(LedgerText.money(check.upcomingRecurring)).",
            "Left before this purchase: \(LedgerText.money(check.leftBefore)). Left after it: \(LedgerText.money(check.leftAfter)).",
            verdict
        ].joined(separator: "\n")
    }

    static func goals(_ goals: [AssistantContext.GoalLine]) -> String {
        guard !goals.isEmpty else { return "No savings goals are set." }
        return (["Savings goals:"] + goals.map {
            "- \($0.name): saved \(LedgerText.money($0.saved)) of \(LedgerText.money($0.target)) (\(PercentFormatter.string(from: $0.fractionSaved, locale: Locale(identifier: "en_US"))))"
        }).joined(separator: "\n")
    }

    static func recurring(_ charges: [AssistantContext.RecurringCharge]) -> String {
        guard !charges.isEmpty else { return "No recurring charges are set up." }
        let total = charges.map(\.monthlyAmount).sum()
        return (["Recurring charges, \(LedgerText.money(total)) a month in total:"] + charges.map {
            "- \($0.merchant) (\($0.category.title)): \(LedgerText.money($0.monthlyAmount)) a month\($0.isUpcoming ? ", still due this month" : "")"
        }).joined(separator: "\n")
    }
}
