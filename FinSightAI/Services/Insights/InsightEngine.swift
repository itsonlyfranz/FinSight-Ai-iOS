import Foundation

/// Deterministic insight engine: pure Swift over a window of ledger history, no AI, no I/O.
///
/// Same input, same output. Every figure in an `Insight` is computed from the entries it is given.
struct InsightEngine: Sendable {
    init() {}

    func insights(for input: InsightInput) -> [Insight] {
        let context = InsightContext(input)
        guard !context.entries.isEmpty else { return [] }

        let recurring = RecurringChargeDetector(configuration: context.configuration)
            .detect(in: context.entries, now: context.now, calendar: context.calendar)

        let categoryAnomalies = categoryAnomalyInsights(context)
        let anomalousCategories = Set(categoryAnomalies.compactMap(\.category))
        // A category-level outlier already explains a large increase; don't report it twice.
        let changes = categoryChangeInsights(context)
            .filter { !($0.severity >= .notice && $0.category.map(anomalousCategories.contains) == true) }

        let all = budgetInsights(context)
            + changes
            + categoryAnomalies
            + merchantAnomalyInsights(context, recurring: recurring)
            + recurringInsights(context, recurring: recurring)
            + savingsRateInsights(context)
            + runwayInsights(context)
            + streakInsights(context)

        return Self.ranked(all)
    }

    /// Most severe first, then largest impact, then a stable tiebreak.
    static func ranked(_ insights: [Insight]) -> [Insight] {
        insights.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.impactAmount != rhs.impactAmount { return lhs.impactAmount > rhs.impactAmount }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Budgets

    func budgetInsights(_ context: InsightContext) -> [Insight] {
        let spentByCategory = context.totalsByCategory(context.currentSpending)
        let period = context.periodKey(context.monthStart)
        var result: [Insight] = []

        for budget in context.budgets where budget.limit > 0 && budget.category.countsAsSpending {
            let category = budget.category
            let spent = spentByCategory[category] ?? 0
            let name = category.title

            if spent > budget.limit {
                let over = spent - budget.limit
                let ratio = (spent / budget.limit).doubleValue
                let remainingNote = context.daysLeft > 0
                    ? "Hold \(name.lowercased()) spending for the \(context.daysLeft) day\(context.daysLeft == 1 ? "" : "s") left this month, or raise the budget if the limit is unrealistic."
                    : "Review what pushed \(name.lowercased()) over and adjust next month's budget if the limit is unrealistic."
                result.append(Insight(
                    id: "budgetBreach:\(category.rawValue):\(period)",
                    kind: .budgetBreach,
                    severity: ratio >= 1.25 ? .critical : .warning,
                    title: "\(name) is over budget",
                    summary: "You've used \(ratio.wholePercent)% of your \(name.lowercased()) budget.",
                    impactAmount: over,
                    evidence: [
                        .init("Spent this month", .money(spent)),
                        .init("Budget", .money(budget.limit)),
                        .init("Over by", .money(over)),
                        .init("Budget used", .percent(ratio))
                    ],
                    suggestedAction: remainingNote,
                    category: category
                ))
                continue
            }

            guard context.elapsedDays >= context.configuration.minimumElapsedDaysForProjection,
                  context.daysLeft > 0, spent > 0 else { continue }
            let dailyRate = spent / Decimal(context.elapsedDays)
            let projected = context.projectedMonthTotal(spent: spent)
            guard projected > budget.limit else { continue }
            let projectedOver = projected - budget.limit
            let ratio = (projected / budget.limit).doubleValue
            let dailyAllowance = max(0, (budget.limit - spent) / Decimal(context.daysLeft))
            result.append(Insight(
                id: "projectedOverrun:\(category.rawValue):\(period)",
                kind: .projectedOverrun,
                severity: ratio >= 1.25 ? .warning : .notice,
                title: "\(name) is on pace to go over budget",
                summary: "At your current pace \(name.lowercased()) will end the month \(Int(((ratio - 1) * 100).rounded()))% over budget.",
                impactAmount: projectedOver,
                evidence: [
                    .init("Spent so far", .money(spent)),
                    .init("Daily run rate", .money(dailyRate)),
                    .init("Days left", .days(context.daysLeft)),
                    .init("Projected month total", .money(projected)),
                    .init("Budget", .money(budget.limit))
                ],
                suggestedAction: "Keep \(name.lowercased()) under \(Self.plain(dailyAllowance)) a day to finish within budget.",
                category: category
            ))
        }
        return result
    }

    /// Plain number for use inside sentences; the card shows locale-formatted figures in its evidence.
    static func plain(_ value: Decimal) -> String {
        value.rounded(scale: 0).formatted(.number.grouping(.never))
    }

    // MARK: - Month-over-month change

    private struct Comparison {
        let current: [LedgerEntry]
        let prior: [LedgerEntry]
        let periodKey: String
        let currentLabel: String
        let priorLabel: String
    }

    private func comparison(_ context: InsightContext) -> Comparison? {
        let previous = context.month(-1)
        if context.elapsedDays >= context.configuration.minimumElapsedDaysForPace {
            // Same number of days on both sides, so day 10 is never compared with a whole month.
            let previousDays = context.calendar.range(of: .day, in: .month, for: previous)?.count ?? 30
            let window = min(context.elapsedDays, previousDays)
            guard let end = context.calendar.date(byAdding: .day, value: window, to: previous) else { return nil }
            return Comparison(
                current: context.currentSpending,
                prior: context.spending(inMonth: previous).filter { $0.date < end },
                periodKey: context.periodKey(context.monthStart),
                currentLabel: "This month so far",
                priorLabel: "Same days last month"
            )
        }
        return Comparison(
            current: context.spending(inMonth: previous),
            prior: context.spending(inMonth: context.month(-2)),
            periodKey: context.periodKey(previous),
            currentLabel: "Last month",
            priorLabel: "Month before"
        )
    }

    func categoryChangeInsights(_ context: InsightContext) -> [Insight] {
        guard let comparison = comparison(context) else { return [] }
        let current = context.totalsByCategory(comparison.current)
        let prior = context.totalsByCategory(comparison.prior)
        let priorTotal = prior.values.sum()
        guard priorTotal > 0 else { return [] }
        let materiality = priorTotal * context.configuration.materialShareOfSpending
        let threshold = context.configuration.categoryChangeThreshold

        return Set(current.keys).union(prior.keys).sorted { $0.rawValue < $1.rawValue }.compactMap { category in
            let now = current[category] ?? 0
            let before = prior[category] ?? 0
            let delta = now - before
            guard abs(delta) >= materiality, delta != 0 else { return nil }

            let name = category.title
            let change: Double? = before > 0 ? (delta / before).doubleValue : nil
            let isIncrease = delta > 0
            if let change {
                guard abs(change) >= threshold else { return nil }
            }
            let severity: Insight.Severity
            if !isIncrease {
                severity = .info
            } else if change == nil || (change ?? 0) >= 1 {
                severity = .warning
            } else {
                severity = .notice
            }
            let changeText = change.map { "\(abs($0).wholePercent)%" }
            var evidence: [Insight.Evidence] = [
                .init(comparison.currentLabel, .money(now)),
                .init(comparison.priorLabel, .money(before)),
                .init("Change", .money(delta))
            ]
            if let change { evidence.append(.init("Change %", .percent(change))) }

            return Insight(
                id: "categoryChange:\(category.rawValue):\(comparison.periodKey)",
                kind: .categoryChange,
                severity: severity,
                title: isIncrease ? "\(name) spending is up" : "\(name) spending is down",
                summary: changeText.map { "\(name) is \(isIncrease ? "up" : "down") \($0) against \(comparison.priorLabel.lowercased())." }
                    ?? "\(name) had no spending \(comparison.priorLabel.lowercased()) but has \(comparison.currentLabel.lowercased()).",
                impactAmount: abs(delta),
                evidence: evidence,
                suggestedAction: isIncrease
                    ? "Look at your recent \(name.lowercased()) purchases and decide which ones were worth it."
                    : "Nice work. Keep the same habits to hold on to the savings.",
                category: category
            )
        }
    }

    // MARK: - Anomalies

    func categoryAnomalyInsights(_ context: InsightContext) -> [Insight] {
        let config = context.configuration
        let months = context.completeMonths(limit: config.baselineMonths)
        guard months.count >= config.minimumBaselineMonths else { return [] }

        let monthlyTotals = months.map { context.total(context.spending(inMonth: $0)) }
        let typicalTotal = InsightStatistics.median(monthlyTotals)
        guard typicalTotal > 0 else { return [] }
        let materiality = typicalTotal * config.materialShareOfSpending

        let currentByCategory = context.totalsByCategory(context.currentSpending)
        let historyByCategory = months.map { context.totalsByCategory(context.spending(inMonth: $0)) }
        let period = context.periodKey(context.monthStart)
        let isExtrapolated = context.elapsedDays >= config.minimumElapsedDaysForPace

        return currentByCategory.keys.sorted { $0.rawValue < $1.rawValue }.compactMap { category in
            let spent = currentByCategory[category] ?? 0
            guard spent > 0 else { return nil }
            let value = isExtrapolated ? context.projectedMonthTotal(spent: spent) : spent
            let baseline = InsightStatistics.baseline(
                of: historyByCategory.map { $0[category] ?? 0 },
                absoluteFloor: typicalTotal * Decimal(string: "0.02")!
            )
            let z = baseline.zScore(of: value)
            guard value > baseline.median, value - baseline.median >= materiality, z >= config.anomalyZThreshold else { return nil }

            let name = category.title
            return Insight(
                id: "categoryAnomaly:\(category.rawValue):\(period)",
                kind: .categoryAnomaly,
                severity: z >= config.strongAnomalyZThreshold ? .warning : .notice,
                title: "Unusual \(name.lowercased()) spending",
                summary: "\(name) is far above its usual monthly level over the last \(baseline.sampleCount) months.",
                impactAmount: value - baseline.median,
                evidence: [
                    .init(isExtrapolated ? "Projected this month" : "Spent this month", .money(value)),
                    .init("Typical month (median)", .money(baseline.median)),
                    .init("Typical variation (MAD)", .money(baseline.mad)),
                    .init("Robust z-score", .number(z)),
                    .init("Months compared", .count(baseline.sampleCount))
                ],
                suggestedAction: "Check this month's \(name.lowercased()) transactions for one-off purchases or anything you didn't expect.",
                category: category
            )
        }
    }

    func merchantAnomalyInsights(_ context: InsightContext, recurring: [DetectedRecurringCharge]) -> [Insight] {
        let config = context.configuration
        let months = context.completeMonths(limit: config.baselineMonths)
        guard !months.isEmpty else { return [] }
        let recurringKeys = Set(recurring.map(\.key))

        let history = Dictionary(
            grouping: months.flatMap { context.spending(inMonth: $0) },
            by: { MerchantNormalizer.key(for: $0.merchant) }
        )
        let current = Dictionary(grouping: context.currentSpending, by: { MerchantNormalizer.key(for: $0.merchant) })

        let candidates: [Insight] = current.keys.sorted().compactMap { key in
            guard !key.isEmpty, !recurringKeys.contains(key),
                  let past = history[key], past.count >= config.merchantAnomalyMinimumHistory,
                  let entries = current[key] else { return nil }
            let baseline = InsightStatistics.baseline(of: past.map(\.amount))
            guard baseline.median > 0 else { return nil }
            let outlier = entries
                .filter { $0.amount > baseline.median * config.merchantAnomalyMinimumRatio && baseline.zScore(of: $0.amount) >= config.anomalyZThreshold }
                .max { ($0.amount, $0.id.uuidString) < ($1.amount, $1.id.uuidString) }
            guard let outlier else { return nil }

            let z = baseline.zScore(of: outlier.amount)
            let merchant = outlier.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            return Insight(
                id: "merchantAnomaly:\(key):\(context.dayKey(outlier.date))",
                kind: .merchantAnomaly,
                severity: z >= config.strongAnomalyZThreshold ? .warning : .notice,
                title: "Unusually large charge at \(merchant)",
                summary: "This \(merchant) charge is \((outlier.amount / baseline.median).doubleValue.formatted(.number.precision(.fractionLength(1))))× your usual.",
                impactAmount: outlier.amount - baseline.median,
                evidence: [
                    .init("This charge", .money(outlier.amount)),
                    .init("Usual charge (median)", .money(baseline.median)),
                    .init("Robust z-score", .number(z)),
                    .init("Date", .date(outlier.date)),
                    .init("Past charges compared", .count(baseline.sampleCount))
                ],
                suggestedAction: "Confirm the amount is right. If it isn't, contact \(merchant) about the charge.",
                category: outlier.category,
                merchant: merchant
            )
        }
        return Array(
            candidates
                .sorted { ($0.impactAmount, $1.id) > ($1.impactAmount, $0.id) }
                .prefix(config.maximumMerchantAnomalies)
        )
    }

    // MARK: - Recurring charges and price creep

    func recurringInsights(_ context: InsightContext, recurring: [DetectedRecurringCharge]) -> [Insight] {
        guard !recurring.isEmpty else { return [] }
        let config = context.configuration
        let period = context.periodKey(context.monthStart)
        var result: [Insight] = []

        let monthlyTotal = recurring.map(\.monthlyEquivalent).sum()
        let income = context.recurringMonthlyIncome
        let incomeShare: Double? = income > 0 ? (monthlyTotal / income).doubleValue : nil
        var evidence: [Insight.Evidence] = recurring.prefix(6).map {
            .init("\($0.merchant) · \($0.cadence.title)", .money($0.latestAmount))
        }
        evidence.append(.init("Detected charges", .count(recurring.count)))
        if let incomeShare { evidence.append(.init("Share of income", .percent(incomeShare))) }
        result.append(Insight(
            id: "recurringCharges:\(period)",
            kind: .recurringCharges,
            severity: (incomeShare ?? 0) >= 0.5 ? .notice : .info,
            title: "\(recurring.count) recurring charge\(recurring.count == 1 ? "" : "s") detected",
            summary: "Repeating payments add up to about \(Self.plain(monthlyTotal)) a month.",
            impactAmount: monthlyTotal,
            evidence: evidence,
            suggestedAction: "Review the list and cancel anything you no longer use.",
            merchant: nil
        ))

        for charge in recurring where charge.isFixedAmount {
            let base = charge.previousAmount
            guard base > 0,
                  charge.latestAmount >= base * (1 + config.priceCreepThreshold),
                  charge.latestAmount <= base * 2,
                  RecurringChargeDetector.days(from: charge.lastDate, to: context.today, calendar: context.calendar) <= config.priceCreepRecencyDays
            else { continue }
            let increase = charge.latestAmount - base
            let fraction = (increase / base).doubleValue
            let annual = increase * Decimal(charge.cadence.chargesPerYear)
            result.append(Insight(
                id: "priceCreep:\(charge.key):\(context.periodKey(context.calendar.dateInterval(of: .month, for: charge.lastDate)?.start ?? charge.lastDate))",
                kind: .priceCreep,
                severity: fraction >= 0.1 ? .warning : .notice,
                title: "\(charge.merchant) raised its price",
                summary: "\(charge.merchant) now charges \(fraction.wholePercent)% more than its previous \(charge.cadence.title) charge.",
                impactAmount: annual,
                evidence: [
                    .init("Previous charge", .money(base)),
                    .init("Latest charge", .money(charge.latestAmount)),
                    .init("Increase", .percent(fraction)),
                    .init("Extra cost per year", .money(annual)),
                    .init("Charged", .text(charge.cadence.title))
                ],
                suggestedAction: "Decide whether \(charge.merchant) is still worth the higher price, or look for a cheaper plan.",
                category: charge.category,
                merchant: charge.merchant
            ))
        }
        return result
    }

    // MARK: - Savings rate

    func savingsRateInsights(_ context: InsightContext) -> [Insight] {
        let previous = context.month(-1)
        let spent = context.total(context.spending(inMonth: previous))
        let logged = context.total(context.entries(inMonth: previous).filter(\.countsAsIncome))
        let income = context.recurringMonthlyIncome + logged
        guard spent > 0, income > 0 else { return [] }

        let saved = income - spent
        let rate = (saved / income).doubleValue
        let target = context.configuration.savingsRateTarget
        let severity: Insight.Severity
        switch rate {
        case ..<0: severity = .critical
        case ..<0.1: severity = .warning
        case ..<0.2: severity = .notice
        default: severity = .info
        }
        let gap = income * target - saved
        let belowTarget = gap > 0
        let name = MonthNames.name(of: previous, calendar: context.calendar)
        return [Insight(
            id: "savingsRate:\(context.periodKey(previous))",
            kind: .savingsRate,
            severity: severity,
            title: rate < 0 ? "You spent more than you earned" : "You saved \(rate.wholePercent)% of your income",
            summary: belowTarget
                ? "\(name) savings rate was \(rate.wholePercent)%, against a \(Double(truncating: target as NSNumber).wholePercent)% target."
                : "\(name) savings rate was \(rate.wholePercent)%, at or above your \(Double(truncating: target as NSNumber).wholePercent)% target.",
            impactAmount: belowTarget ? gap : saved,
            evidence: [
                .init("Income", .money(income)),
                .init("Spending", .money(spent)),
                .init("Saved", .money(saved)),
                .init("Savings rate", .percent(rate)),
                .init("Target rate", .percent(Double(truncating: target as NSNumber)))
            ],
            suggestedAction: belowTarget
                ? "Set aside money on payday, before spending, to close the gap to your target."
                : "Keep it up. Consider moving the surplus into a savings goal."
        )]
    }

    // MARK: - Emergency runway

    func runwayInsights(_ context: InsightContext) -> [Insight] {
        guard let typical = context.typicalMonthlySpending, typical > 0 else { return [] }
        let reserve = max(0, context.reserveBalance)
        let months = (reserve / typical).doubleValue
        var severity: Insight.Severity
        switch months {
        case ..<1: severity = .critical
        case ..<3: severity = .warning
        case ..<6: severity = .notice
        default: severity = .info
        }
        // A zero balance more likely means "not tracked yet" than "no money at all".
        if reserve == 0 { severity = min(severity, .warning) }

        let gap: Decimal
        if months < 3 {
            gap = typical * 3 - reserve
        } else if months < 6 {
            gap = typical * 6 - reserve
        } else {
            gap = reserve
        }
        let milestone = months < 3 ? 3 : 6
        let rounded = (months * 10).rounded() / 10
        return [Insight(
            id: "emergencyRunway:\(context.periodKey(context.monthStart))",
            kind: .emergencyRunway,
            severity: severity,
            title: reserve == 0 ? "No emergency fund yet" : "Emergency fund covers \(rounded.formatted(.number.precision(.fractionLength(0...1)))) months",
            summary: months >= 6
                ? "Your reserve covers six months or more of typical spending."
                : "Your reserve covers \(rounded.formatted(.number.precision(.fractionLength(0...1)))) months of typical spending; \(milestone) is a common minimum.",
            impactAmount: gap,
            evidence: [
                .init("Reserve", .money(reserve)),
                .init("Typical monthly spending", .money(typical)),
                .init("Runway", .months(months)),
                .init(months >= 6 ? "Reserve" : "Needed for \(milestone) months", .money(months >= 6 ? reserve : typical * Decimal(milestone)))
            ],
            suggestedAction: months >= 6
                ? "You're well covered. Extra savings can go toward other goals."
                : "Automate a monthly transfer to an emergency-fund goal until it reaches \(milestone) months of spending."
        )]
    }

    // MARK: - No-spend streak

    func streakInsights(_ context: InsightContext) -> [Insight] {
        let spending = context.entries.filter(\.countsAsSpending)
        guard let firstSpend = spending.map(\.date).min() else { return [] }
        let calendar = context.calendar
        let firstDay = calendar.startOfDay(for: firstSpend)
        let spendDays = Set(spending.map { calendar.startOfDay(for: $0.date) })

        // Completed days only: today isn't over, so it can't extend the streak yet.
        var streak = 0
        var day = Self.previousDay(of: context.today, calendar: calendar)
        while streak < context.configuration.maximumStreakLookbackDays, day >= firstDay, !spendDays.contains(day) {
            streak += 1
            day = Self.previousDay(of: day, calendar: calendar)
        }
        guard streak >= context.configuration.minimumNoSpendStreak else { return [] }

        let startDay = Self.nextDay(of: day, calendar: calendar)
        let avoided = (context.typicalMonthlySpending ?? 0) / 30 * Decimal(streak)
        return [Insight(
            id: "noSpendStreak:\(context.dayKey(startDay))",
            kind: .noSpendStreak,
            severity: .info,
            title: "\(streak)-day no-spend streak",
            summary: "You haven't spent anything for \(streak) days in a row.",
            impactAmount: avoided,
            evidence: [
                .init("Streak", .days(streak)),
                .init("Since", .date(startDay)),
                .init("Typical daily spending", .money((context.typicalMonthlySpending ?? 0) / 30))
            ],
            suggestedAction: "Keep it going. Moving the money you didn't spend into savings makes the streak count."
        )]
    }

    private static func previousDay(of day: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: -1, to: day) ?? day)
    }

    private static func nextDay(of day: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: day) ?? day)
    }
}

enum MonthNames {
    static func name(of monthStart: Date, calendar: Calendar) -> String {
        Date.FormatStyle(
            date: nil,
            time: nil,
            locale: Locale(identifier: "en_US"),
            calendar: calendar,
            timeZone: calendar.timeZone,
            capitalizationContext: .standalone
        ).month(.wide).format(monthStart)
    }
}
