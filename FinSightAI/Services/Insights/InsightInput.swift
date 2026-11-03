import Foundation

/// Immutable, `Sendable` copy of a transaction for the engine (the live SwiftData model is neither).
struct LedgerEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let amount: Decimal
    let kind: TransactionKind
    let category: SpendingCategory
    let merchant: String
    let date: Date

    init(
        id: UUID = UUID(),
        amount: Decimal,
        kind: TransactionKind = .expense,
        category: SpendingCategory,
        merchant: String = "",
        date: Date
    ) {
        self.id = id
        self.amount = amount
        self.kind = kind
        self.category = category
        self.merchant = merchant
        self.date = date
    }

    init(_ record: TransactionRecord) {
        self.init(
            id: record.id,
            amount: record.amount,
            kind: record.kind,
            category: record.category,
            merchant: record.merchantName,
            date: record.date
        )
    }

    /// Mirrors `TransactionRecord.countsAsSpending`.
    var countsAsSpending: Bool { kind == .expense && category.countsAsSpending }
    var countsAsIncome: Bool { kind == .income }
}

/// A category's monthly limit for the month being analysed (rollover already included).
struct BudgetLimit: Equatable, Sendable {
    let category: SpendingCategory
    let limit: Decimal
}

/// A savings goal's name and balance, used to size the emergency reserve.
struct GoalBalance: Equatable, Sendable {
    let name: String
    let saved: Decimal
}

enum ReserveCalculator {
    /// Money available as an emergency reserve: goals whose name mentions "emergency" if there are
    /// any, otherwise every goal's saved balance.
    static func reserve(from goals: [GoalBalance]) -> Decimal {
        let emergency = goals.filter { $0.name.localizedCaseInsensitiveContains("emergency") }
        return (emergency.isEmpty ? goals : emergency).map(\.saved).sum()
    }
}

/// Tunable thresholds. The defaults are what the app ships with; tests vary them.
struct InsightEngineConfiguration: Equatable, Sendable {
    /// Complete months before the current one used as the baseline for anomalies.
    var baselineMonths = 6
    /// Months of history needed before an anomaly can be judged.
    var minimumBaselineMonths = 3
    /// Day of the month from which month-to-date figures are extrapolated or compared.
    var minimumElapsedDaysForPace = 7
    /// Day of the month from which budget run-rates are projected.
    var minimumElapsedDaysForProjection = 5
    /// Robust z-score at which something counts as an outlier (Iglewicz & Hoaglin's 3.5).
    var anomalyZThreshold = 3.5
    /// Robust z-score at which an anomaly is raised from `notice` to `warning`.
    var strongAnomalyZThreshold = 7.0
    /// A merchant charge must also be this many times the usual charge to count as anomalous.
    var merchantAnomalyMinimumRatio = Decimal(string: "1.5")!
    var merchantAnomalyMinimumHistory = 3
    var maximumMerchantAnomalies = 3
    /// Change versus the comparison period needed to report a category move.
    var categoryChangeThreshold = 0.25
    /// A move must be at least this share of the comparison period's total spending to matter.
    var materialShareOfSpending = Decimal(string: "0.05")!
    var recurringMinimumOccurrences = 3
    /// Charges may differ from the median by this share and still be one recurring series.
    var recurringAmountTolerance = Decimal(string: "0.3")!
    /// Fraction of gaps that must match the cadence.
    var recurringGapAgreement = 0.75
    /// A recurring series is active while its last charge is within this many cadence lengths.
    var recurringActiveCadenceMultiple = 1.5
    /// Increase over the previous charge that counts as price creep.
    var priceCreepThreshold = Decimal(string: "0.03")!
    /// Only creep on a charge this recent is reported.
    var priceCreepRecencyDays = 45
    var savingsRateTarget = Decimal(string: "0.2")!
    /// Complete months averaged for typical spending.
    var typicalSpendingMonths = 3
    var minimumNoSpendStreak = 2
    var maximumStreakLookbackDays = 90
}

/// Everything the engine needs, as plain values.
struct InsightInput: Sendable {
    var now: Date
    var calendar: Calendar
    /// Transactions covering the history window. Anything outside the window or after today is ignored.
    var entries: [LedgerEntry]
    var budgets: [BudgetLimit]
    /// Sum of the active recurring income sources.
    var recurringMonthlyIncome: Decimal
    var reserveBalance: Decimal
    var configuration: InsightEngineConfiguration

    init(
        now: Date,
        calendar: Calendar = .current,
        entries: [LedgerEntry],
        budgets: [BudgetLimit] = [],
        recurringMonthlyIncome: Decimal = 0,
        reserveBalance: Decimal = 0,
        configuration: InsightEngineConfiguration = InsightEngineConfiguration()
    ) {
        self.now = now
        self.calendar = calendar
        self.entries = entries
        self.budgets = budgets
        self.recurringMonthlyIncome = recurringMonthlyIncome
        self.reserveBalance = reserveBalance
        self.configuration = configuration
    }
}
