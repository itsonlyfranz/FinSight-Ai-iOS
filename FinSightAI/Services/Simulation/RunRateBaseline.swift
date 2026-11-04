import Foundation

/// A recurring charge the simulator can pause.
struct RecurringCharge: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let category: SpendingCategory
    let monthlyAmount: Decimal
}

/// What a typical full month of spending looks like, per category: the starting point every
/// what-if is measured from.
///
/// It fixes the audit's D8: a month-to-date total is tiny early in the month, so recent spending
/// is scaled to a full month instead. Only real spending counts: transfers, income and savings
/// are left out, and so are one-off purchases, which would otherwise make a single big buy look
/// like a monthly habit. Recurring charges are added once at their monthly amount rather than
/// scaled, and kept apart so a category cut can never count the same money as pausing the charge.
struct RunRateBaseline: Equatable, Sendable {
    /// One category's typical month.
    struct Line: Identifiable, Equatable, Sendable {
        let category: SpendingCategory
        /// Everyday spending scaled to a full month. This is what a category cut applies to.
        let discretionary: Decimal
        /// Active recurring charges in the category, at their monthly amounts.
        let recurring: Decimal

        var id: SpendingCategory { category }
        var total: Decimal { discretionary + recurring }
    }

    /// Window of recent days the run-rate is observed over.
    static let windowDays = 30
    /// Spending observed over fewer days than this is scaled as if it had covered this many.
    static let minimumObservedDays = 7
    /// A purchase this many times its category's usual size is a one-off.
    static let oneOffMultiple: Decimal = 4
    /// For a category with too few purchases to judge, a purchase this many times the usual size
    /// overall is a one-off. Higher, because one large grocery shop is not a one-off.
    static let thinCategoryMultiple: Decimal = 10
    /// Purchases in a category needed before its own median is trusted.
    static let minimumCategorySamples = 3
    /// Purchases overall needed before the overall median stands in for a thin category.
    static let minimumOverallSamples = 5
    /// Complete months of history needed to estimate how much spending swings.
    static let minimumVolatilityMonths = 3
    static let volatilityMonths = 6

    /// Categories with spending, largest first.
    let lines: [Line]
    /// Purchases left out of the run-rate as one-offs.
    let excludedOneOffs: [LedgerEntry]
    let recurringCharges: [RecurringCharge]
    /// Standard deviation of each category's month-to-month everyday spending. Empty without enough
    /// history (`minimumVolatilityMonths` complete months).
    let categoryVolatility: [SpendingCategory: Decimal]

    static let empty = RunRateBaseline(lines: [], excludedOneOffs: [], recurringCharges: [], categoryVolatility: [:])

    var discretionaryTotal: Decimal { lines.map(\.discretionary).sum() }
    var recurringTotal: Decimal { lines.map(\.recurring).sum() }
    var monthlyTotal: Decimal { discretionaryTotal + recurringTotal }
    var excludedOneOffTotal: Decimal { excludedOneOffs.map(\.amount).sum() }
    var isEmpty: Bool { lines.isEmpty }
    var hasVolatilityHistory: Bool { !categoryVolatility.isEmpty }

    /// How much a month's savings from `cuts` is likely to swing: a cut saves a share of the
    /// category's spending, so it inherits that share of the category's own swings. Independent
    /// swings add in quadrature. Nil without enough history to say.
    func savingsVolatility(for cuts: [CategoryCut]) -> Decimal? {
        guard hasVolatilityHistory else { return nil }
        let squares = cuts.reduce(0.0) { total, cut in
            let swing = (categoryVolatility[cut.category] ?? 0).doubleValue * Double(cut.percent) / 100
            return total + swing * swing
        }
        return Decimal(squares.squareRoot()).rounded(scale: 2)
    }

    func line(for category: SpendingCategory) -> Line? {
        lines.first { $0.category == category }
    }

    /// Categories a cut slider is offered for: those with everyday spending, largest first.
    var cuttableLines: [Line] {
        lines.filter { $0.discretionary > 0 }.sorted {
            $0.discretionary != $1.discretionary ? $0.discretionary > $1.discretionary : $0.category.rawValue < $1.category.rawValue
        }
    }

    // MARK: - Building

    /// - Parameters:
    ///   - entries: the ledger. Only expenses count; transfers and income are ignored.
    ///   - recurring: the active recurring charges, each added once at its monthly amount.
    ///   - recurringTransactionIDs: transactions already matched to a recurring charge, so they
    ///     are not counted a second time.
    static func make(
        entries: [LedgerEntry],
        recurring: [RecurringCharge] = [],
        recurringTransactionIDs: Set<UUID> = [],
        now: Date,
        calendar: Calendar = .current
    ) -> RunRateBaseline {
        let recurringCharges = recurring.filter { $0.category.countsAsSpending && $0.monthlyAmount > 0 }
        let today = calendar.startOfDay(for: now)
        guard let windowEnd = calendar.date(byAdding: .day, value: 1, to: today),
              let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) else {
            return RunRateBaseline(lines: lines(everyday: [:], recurring: recurringCharges), excludedOneOffs: [], recurringCharges: recurringCharges, categoryVolatility: [:])
        }

        let everyday = entries.filter { $0.countsAsSpending && !recurringTransactionIDs.contains($0.id) }
        let recent = everyday.filter { $0.date >= windowStart && $0.date < windowEnd }
        let oneOffIDs = Set(oneOffs(in: recent).map(\.id))
        let kept = recent.filter { !oneOffIDs.contains($0.id) }

        var perCategory: [SpendingCategory: Decimal] = [:]
        if let earliest = recent.map(\.date).min() {
            let earliestDay = calendar.startOfDay(for: earliest)
            let observed = (calendar.dateComponents([.day], from: earliestDay, to: today).day ?? 0) + 1
            let observedDays = Decimal(min(max(observed, minimumObservedDays), windowDays))
            let perDay = Dictionary(grouping: kept, by: \.category).mapValues { $0.map(\.amount).sum() }
            for (category, total) in perDay {
                // Multiply before dividing so a total that scales evenly stays exact.
                perCategory[category] = (total * Decimal(windowDays) / observedDays).rounded(scale: 2)
            }
        }

        return RunRateBaseline(
            lines: lines(everyday: perCategory, recurring: recurringCharges),
            excludedOneOffs: recent.filter { oneOffIDs.contains($0.id) }.sorted { $0.date > $1.date },
            recurringCharges: recurringCharges,
            categoryVolatility: volatility(of: everyday, now: now, calendar: calendar)
        )
    }

    private static func lines(everyday: [SpendingCategory: Decimal], recurring: [RecurringCharge]) -> [Line] {
        let recurringByCategory = Dictionary(grouping: recurring, by: \.category).mapValues { $0.map(\.monthlyAmount).sum() }
        let categories = Set(everyday.keys).union(recurringByCategory.keys)
        return categories
            .map { Line(category: $0, discretionary: everyday[$0] ?? 0, recurring: recurringByCategory[$0] ?? 0) }
            .filter { $0.total > 0 }
            .sorted { $0.total != $1.total ? $0.total > $1.total : $0.category.rawValue < $1.category.rawValue }
    }

    // MARK: - One-offs

    /// Purchases at least `oneOffMultiple` times their category's usual size (its median, once the
    /// category has `minimumCategorySamples` purchases), or `thinCategoryMultiple` times the usual
    /// size overall for a category with too few purchases to judge.
    static func oneOffs(in entries: [LedgerEntry]) -> [LedgerEntry] {
        let overall = entries.count >= minimumOverallSamples ? InsightStatistics.median(entries.map(\.amount)) : nil
        let byCategory = Dictionary(grouping: entries, by: \.category)
        return entries.filter { entry in
            let siblings = byCategory[entry.category] ?? []
            let reference: Decimal?
            let multiple: Decimal
            if siblings.count >= minimumCategorySamples {
                reference = InsightStatistics.median(siblings.map(\.amount))
                multiple = oneOffMultiple
            } else {
                reference = overall
                multiple = thinCategoryMultiple
            }
            guard let reference, reference > 0 else { return false }
            return entry.amount >= reference * multiple
        }
    }

    // MARK: - Volatility

    /// Sample standard deviation of each category's everyday spending (one-offs excluded) across the
    /// complete months before this one that have any spending. Empty with fewer than
    /// `minimumVolatilityMonths` such months.
    static func volatility(of entries: [LedgerEntry], now: Date, calendar: Calendar) -> [SpendingCategory: Decimal] {
        guard let currentStart = calendar.dateInterval(of: .month, for: now)?.start else { return [:] }
        var months: [[SpendingCategory: Decimal]] = []
        for offset in 1...volatilityMonths {
            guard let monthAnchor = calendar.date(byAdding: .month, value: -offset, to: currentStart),
                  let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { continue }
            let month = entries.filter { $0.date >= interval.start && $0.date < interval.end }
            guard !month.isEmpty else { continue }
            let oneOffIDs = Set(oneOffs(in: month).map(\.id))
            let kept = month.filter { !oneOffIDs.contains($0.id) }
            months.append(Dictionary(grouping: kept, by: \.category).mapValues { $0.map(\.amount).sum() })
        }
        guard months.count >= minimumVolatilityMonths else { return [:] }
        let categories = Set(months.flatMap(\.keys))
        var result: [SpendingCategory: Decimal] = [:]
        for category in categories {
            // A month without spending in the category counts as 0, not as missing.
            let totals = months.map { ($0[category] ?? 0).doubleValue }
            let mean = totals.reduce(0, +) / Double(totals.count)
            let squares = totals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +)
            result[category] = Decimal((squares / Double(totals.count - 1)).squareRoot()).rounded(scale: 2)
        }
        return result
    }
}
