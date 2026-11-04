import Foundation
import SwiftData

enum PlanningError: LocalizedError, Equatable {
    case invalidAmount
    case missingName

    var errorDescription: String? {
        switch self {
        case .invalidAmount: String(localized: "Enter an amount greater than zero.")
        case .missingName: String(localized: "Enter a name.")
        }
    }
}

/// Income, budgets, goals and settings. All amounts are validated here, at the boundary, so the
/// views stay thin.
extension AppContext {
    // MARK: - Loading

    func reloadPlanning(now: Date = .now) throws {
        incomeSources = try modelContext.fetch(FetchDescriptor<IncomeSource>(sortBy: [SortDescriptor(\.createdAt)]))
        budgets = try modelContext.fetch(FetchDescriptor<Budget>())
        savingsGoals = try modelContext.fetch(FetchDescriptor<SavingsGoal>(sortBy: [SortDescriptor(\.createdAt)]))
        let calendar = settings?.calendar() ?? .current
        incomeGauge = IncomeCalculator.gauge(sources: incomeSources, transactions: transactions, month: now, calendar: calendar)
        budgetProgress = BudgetCalculator.progress(budgets: budgets, transactions: transactions, month: now, calendar: calendar)
        try reloadEngineInsights(now: now)
    }

    // MARK: - Settings

    var currencyCode: String {
        settings?.currencyCode ?? CurrencyFormatter.currencyCode(for: .current)
    }

    /// Makes the formatter follow the stored currency (which defaults to the device region's).
    func applyCurrencySetting() {
        CurrencyFormatter.setSelectedCurrencyCode(settings?.currencyCode)
    }

    func setCurrency(code: String) throws {
        guard let settings else { return }
        settings.currencyCode = AppSettings.normalizedCurrencyCode(code)
        settings.updatedAt = .now
        try modelContext.save()
        applyCurrencySetting()
    }

    func setFirstWeekday(_ weekday: Int) throws {
        guard let settings else { return }
        settings.firstWeekday = AppSettings.normalizedWeekday(weekday)
        settings.updatedAt = .now
        try modelContext.save()
        try reloadPlanning()
    }

    // MARK: - Income

    var monthlyRecurringIncome: Decimal {
        IncomeCalculator.recurringMonthlyIncome(sources: incomeSources)
    }

    func saveIncomeSource(_ source: IncomeSource?, name: String, monthlyAmount: Decimal?) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlanningError.missingName }
        let amount = try ValidationError.validatedAmount(monthlyAmount)
        if let source {
            source.name = name
            source.monthlyAmount = amount
            source.updatedAt = .now
        } else {
            modelContext.insert(IncomeSource(name: name, monthlyAmount: amount))
        }
        try modelContext.save()
        try reloadPlanning()
    }

    func setIncomeSource(_ source: IncomeSource, active: Bool) throws {
        source.isActive = active
        source.updatedAt = .now
        try modelContext.save()
        try reloadPlanning()
    }

    func delete(_ source: IncomeSource) throws {
        modelContext.delete(source)
        try modelContext.save()
        try reloadPlanning()
    }

    // MARK: - Budgets

    func budget(for category: SpendingCategory) -> Budget? {
        budgets.first { $0.category == category }
    }

    /// Creates or updates the category's budget. A nil or zero amount removes it.
    func setBudget(category: SpendingCategory, monthlyAmount: Decimal?, rollover: Bool = false) throws {
        guard category.countsAsSpending else { return }
        let existing = budget(for: category)
        guard let monthlyAmount, monthlyAmount != 0 else {
            if let existing { modelContext.delete(existing) }
            try modelContext.save()
            try reloadPlanning()
            return
        }
        let amount = try ValidationError.validatedAmount(monthlyAmount)
        if let existing {
            existing.monthlyAmount = amount
            existing.rolloverEnabled = rollover
            existing.updatedAt = .now
        } else {
            modelContext.insert(Budget(category: category, monthlyAmount: amount, rolloverEnabled: rollover))
        }
        try modelContext.save()
        try reloadPlanning()
    }

    func progress(for category: SpendingCategory) -> BudgetProgress? {
        budgetProgress.first { $0.category == category }
    }

    // MARK: - Savings goals

    /// Monthly amount left after spending, split between the unfinished goals.
    var goalSurplusShare: Decimal {
        GoalCalculator.surplusShare(
            monthlyIncome: monthlyRecurringIncome,
            monthlySpending: runRateBaseline.monthlyTotal,
            unfinishedGoals: savingsGoals.filter { !$0.isReached }.count
        )
    }

    func goalProjection(for goal: SavingsGoal, now: Date = .now) -> GoalProjection {
        let calendar = settings?.calendar() ?? .current
        let pace = GoalCalculator.pace(for: goal, surplusShare: goalSurplusShare, now: now, calendar: calendar)
        return GoalCalculator.projection(for: goal, monthlyPace: pace, now: now, calendar: calendar)
    }

    func saveGoal(
        _ goal: SavingsGoal?,
        name: String,
        targetAmount: Decimal?,
        savedAmount: Decimal?,
        targetDate: Date?
    ) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlanningError.missingName }
        let target = try ValidationError.validatedAmount(targetAmount)
        let saved = max(0, savedAmount ?? 0)
        if let goal {
            goal.name = name
            goal.targetAmount = target
            goal.targetDate = targetDate
            goal.updatedAt = .now
        } else {
            modelContext.insert(SavingsGoal(name: name, targetAmount: target, savedAmount: saved, targetDate: targetDate))
        }
        try modelContext.save()
        try reloadPlanning()
    }

    /// Adds a deposit (positive) or withdrawal (negative) to a goal.
    func contribute(to goal: SavingsGoal, amount: Decimal?, withdraw: Bool = false, note: String = "") throws {
        let magnitude = try ValidationError.validatedAmount(amount)
        let delta = withdraw ? -min(magnitude, goal.savedAmount) : magnitude
        guard delta != 0 else { return }
        goal.contribute(delta, note: note)
        try modelContext.save()
        try reloadPlanning()
    }

    func delete(_ goal: SavingsGoal) throws {
        modelContext.delete(goal)
        try modelContext.save()
        try reloadPlanning()
    }

    // MARK: - Export

    var csvExport: TransactionsCSVExport {
        TransactionsCSVExport(transactions: transactions)
    }

    // MARK: - Sample data

    /// Adds example income, budgets and a goal alongside the sample transactions — only into an
    /// otherwise empty plan, so it never overwrites anything the user set up.
    func loadSamplePlanning(now: Date = .now) throws {
        if incomeSources.isEmpty {
            modelContext.insert(IncomeSource(name: "Salary", monthlyAmount: 45_000))
        }
        if budgets.isEmpty {
            let samples: [(SpendingCategory, Decimal)] = [
                (.groceries, 6_000), (.dining, 3_000), (.transport, 2_000), (.bills, 5_000), (.shopping, 2_500)
            ]
            for (category, amount) in samples {
                modelContext.insert(Budget(category: category, monthlyAmount: amount))
            }
        }
        if savingsGoals.isEmpty {
            let goal = SavingsGoal(
                name: "Emergency fund",
                targetAmount: 90_000,
                savedAmount: 0,
                targetDate: Calendar.current.date(byAdding: .month, value: 12, to: now)
            )
            modelContext.insert(goal)
            goal.contribute(15_000, on: now.addingTimeInterval(-86_400 * 30), note: "Opening balance")
        }
        try modelContext.save()
        try reloadPlanning(now: now)
    }
}
