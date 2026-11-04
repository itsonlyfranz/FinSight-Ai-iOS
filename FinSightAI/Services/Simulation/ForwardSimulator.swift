import Foundation

/// The what-if maths: pure functions over `Decimal` money, with no UI, storage or clock of their own.
///
/// Savings compound monthly with the `(balance + deposit) × (1 + yield / 12)` rule: each month's
/// deposit lands first and then the whole balance earns that month's interest. The behaviour is
/// pinned by tests that mirror the Android app's forward-simulator tests.
enum ForwardSimulator {
    /// Months the chart marks, and that the AI explanation quotes.
    static let milestoneMonths = [3, 6, 12]
    /// Longest countdown searched; a goal further away than 50 years is reported as out of reach.
    static let maximumCountdownMonths = 600
    /// Width of the likely range: ±1.2816 standard deviations covers the middle 80% of outcomes.
    static let bandZScore = 1.2816

    // MARK: - Compounding

    /// Monthly interest rate for an annual percentage yield (4.5 → 0.00375). Negative yields count as 0.
    static func monthlyRate(annualYieldPercent: Decimal) -> Decimal {
        max(0, annualYieldPercent) / 100 / 12
    }

    /// Balance after `months` of `(b + d)(1 + r/12)`, rounded to cents. A negative deposit counts as
    /// none and fewer than one month leaves the starting balance untouched.
    static func compoundedBalance(
        startingBalance: Decimal = 0,
        monthlyDeposit: Decimal,
        months: Int,
        annualYieldPercent: Decimal
    ) -> Decimal {
        balances(startingBalance: startingBalance, monthlyDeposit: monthlyDeposit, months: months, annualYieldPercent: annualYieldPercent)
            .last?.rounded(scale: 2) ?? 0
    }

    /// The exact (unrounded) balance at the end of each month from 0 through `months`.
    static func balances(
        startingBalance: Decimal,
        monthlyDeposit: Decimal,
        months: Int,
        annualYieldPercent: Decimal
    ) -> [Decimal] {
        let deposit = max(0, monthlyDeposit)
        let growth = 1 + monthlyRate(annualYieldPercent: annualYieldPercent)
        var balance = max(0, startingBalance)
        var result = [balance]
        guard months > 0 else { return result }
        for _ in 1...months {
            balance = (balance + deposit) * growth
            result.append(balance)
        }
        return result
    }

    /// Whole months until savings that start at `saved` reach `target`, or nil when they never do
    /// within `maximumCountdownMonths`. Without a yield this is Phase 2's plain division
    /// (`GoalCalculator.monthsToReach`); with one the balance is compounded.
    static func monthsToReach(
        target: Decimal,
        saved: Decimal,
        monthlyDeposit: Decimal,
        annualYieldPercent: Decimal
    ) -> Int? {
        let remaining = max(0, target - saved)
        guard remaining > 0 else { return 0 }
        let deposit = max(0, monthlyDeposit)
        if annualYieldPercent <= 0 {
            guard let months = GoalCalculator.monthsToReach(remaining: remaining, monthlyPace: deposit),
                  months <= maximumCountdownMonths else { return nil }
            return months
        }
        let growth = 1 + monthlyRate(annualYieldPercent: annualYieldPercent)
        var balance = max(0, saved)
        guard deposit > 0 || balance > 0 else { return nil }
        for month in 1...maximumCountdownMonths {
            balance = (balance + deposit) * growth
            if balance >= target { return month }
        }
        return nil
    }

    // MARK: - Scenario

    static func simulate(
        baseline: RunRateBaseline,
        scenario rawScenario: SimulationScenario,
        goals: [SimulationGoal] = [],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> SimulationResult {
        let scenario = rawScenario.normalized

        let categorySavings = scenario.cuts.compactMap { cut -> CategorySaving? in
            guard let line = baseline.line(for: cut.category), line.discretionary > 0 else { return nil }
            let saved = (line.discretionary * Decimal(cut.percent) / 100).rounded(scale: 2)
            return CategorySaving(category: cut.category, monthlyBaseline: line.discretionary, percent: cut.percent, saved: saved)
        }.sorted { $0.saved != $1.saved ? $0.saved > $1.saved : $0.category.rawValue < $1.category.rawValue }

        let pausedCharges = baseline.recurringCharges.filter { scenario.pausedRecurringIDs.contains($0.id) }
        let paused = pausedCharges.map(\.monthlyAmount).sum().rounded(scale: 2)
        let daily = (scenario.dailySavings * Decimal(SimulationScenario.daysPerMonth)).rounded(scale: 2)
        let monthly = categorySavings.map(\.saved).sum() + paused + daily

        let exact = balances(
            startingBalance: scenario.startingBalance,
            monthlyDeposit: monthly,
            months: scenario.horizonMonths,
            annualYieldPercent: scenario.annualYieldPercent
        )
        let growth = 1 + monthlyRate(annualYieldPercent: scenario.annualYieldPercent).doubleValue
        let volatility = baseline.savingsVolatility(for: scenario.cuts)?.doubleValue

        let timeline = exact.enumerated().map { month, balance in
            let band = volatility.map { halfWidth(month: month, volatility: $0, growth: growth) }
            return ProjectionPoint(
                month: month,
                date: calendar.date(byAdding: .month, value: month, to: now) ?? now,
                balance: balance.rounded(scale: 2),
                contributed: (scenario.startingBalance + monthly * Decimal(month)).rounded(scale: 2),
                lower: band.map { (balance - $0).rounded(scale: 2) },
                upper: band.map { (balance + $0).rounded(scale: 2) }
            )
        }

        return SimulationResult(
            monthlySavings: monthly,
            categorySavings: categorySavings,
            pausedRecurringSavings: paused,
            pausedRecurringNames: pausedCharges.map(\.name).sorted(),
            dailySavingsPerMonth: daily,
            timeline: timeline,
            goals: goals.map { countdown(for: $0, scenarioSavings: monthly, annualYieldPercent: scenario.annualYieldPercent, now: now, calendar: calendar) },
            hasUncertaintyBand: volatility != nil
        )
    }

    /// Half the likely range after `month` months. A swing of `volatility` in any month's savings is
    /// compounded by the months left to run, and independent swings add in quadrature, so the range
    /// is `z × σ × √(Σ g²ʲ)` for j = 1…month. Display-only, so `Double` is fine here.
    static func halfWidth(month: Int, volatility: Double, growth: Double) -> Decimal {
        guard month > 0, volatility > 0 else { return 0 }
        var variance = 0.0
        var factor = 1.0
        for _ in 1...month {
            factor *= growth
            variance += factor * factor
        }
        return Decimal(bandZScore * volatility * variance.squareRoot()).rounded(scale: 2)
    }

    // MARK: - Goals

    static func countdown(
        for goal: SimulationGoal,
        scenarioSavings: Decimal,
        annualYieldPercent: Decimal,
        now: Date,
        calendar: Calendar
    ) -> GoalCountdown {
        let current = monthsToReach(
            target: goal.targetAmount, saved: goal.savedAmount,
            monthlyDeposit: goal.monthlyPace, annualYieldPercent: annualYieldPercent
        )
        let plan = monthsToReach(
            target: goal.targetAmount, saved: goal.savedAmount,
            monthlyDeposit: goal.monthlyPace + scenarioSavings, annualYieldPercent: annualYieldPercent
        )
        let fundedBy = plan.flatMap { calendar.date(byAdding: .month, value: $0, to: now) }

        let status: GoalCountdown.Status
        if goal.remaining == 0 {
            status = .reached
        } else if plan == nil {
            status = .noPace
        } else if let fundedBy, let targetDate = goal.targetDate, fundedBy > targetDate {
            status = .behind
        } else {
            status = .onTrack
        }
        return GoalCountdown(
            id: goal.id, name: goal.name, targetAmount: goal.targetAmount, remaining: goal.remaining,
            targetDate: goal.targetDate, currentMonths: current, planMonths: plan, fundedBy: fundedBy, status: status
        )
    }
}
