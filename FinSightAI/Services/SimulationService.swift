import Foundation

protocol SimulationService {
    func project(input: SimulationInput) -> SimulationProjection
}

struct DefaultSimulationService: SimulationService {
    func project(input: SimulationInput) -> SimulationProjection {
        // The reduction applies only to discretionary spend. Recurring charges are modelled
        // separately (via pausing), so they are removed from the base to avoid counting
        // the same money twice.
        let discretionarySpend = max(0, input.monthlyRunRate - input.recurringMonthlySpend)
        let reductionSavings = discretionarySpend * (input.reductionPercent / 100)
        let pausedSavings = min(max(0, input.pausedRecurringMonthlySpend), input.recurringMonthlySpend)
        let monthlySavings = max(0, input.dailySavings * 30 + reductionSavings + pausedSavings)
        let monthsToGoal: Int?

        if input.savingsGoal > 0, monthlySavings > 0 {
            monthsToGoal = Int(ceil(input.savingsGoal / monthlySavings))
        } else {
            monthsToGoal = nil
        }

        return SimulationProjection(
            monthlySavings: monthlySavings,
            projectedSavingsThreeMonths: monthlySavings * 3,
            projectedSavingsSixMonths: monthlySavings * 6,
            projectedSavingsTwelveMonths: monthlySavings * 12,
            monthsToGoal: monthsToGoal
        )
    }
}

/// Estimates what a full month of spending looks like from recent history, so the
/// simulator does not start from a month-to-date total that is tiny early in the month.
enum MonthlyRunRate {
    static let windowDays = 30
    static let minimumObservedDays = 7

    /// Extrapolates non-recurring spending to a full month, then adds the active recurring
    /// charges once at their monthly amount so they are never scaled.
    static func estimate(
        from transactions: [TransactionRecord],
        recurringSummary: RecurringSummary = .empty,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Double {
        let recurringSpend = recurringSummary.totalMonthlySpend
        let today = calendar.startOfDay(for: now)
        guard let windowEnd = calendar.date(byAdding: .day, value: 1, to: today),
              let windowStart = calendar.date(byAdding: .day, value: -(windowDays - 1), to: today) else {
            return recurringSpend
        }

        let inWindow = transactions.filter {
            $0.countsAsSpending
                && !recurringSummary.recurringTransactionIDs.contains($0.id)
                && $0.date >= windowStart && $0.date < windowEnd
        }
        guard let earliest = inWindow.map(\.date).min() else { return recurringSpend }

        let total = inWindow.map(\.amount).sum().doubleValue
        let earliestDay = calendar.startOfDay(for: earliest)
        let observed = (calendar.dateComponents([.day], from: earliestDay, to: today).day ?? 0) + 1
        let observedDays = min(max(observed, minimumObservedDays), windowDays)
        return total / Double(observedDays) * Double(windowDays) + recurringSpend
    }
}

/// Tracks which recurring charges the user has paused in the simulator.
/// Charges are included by default; pausing one models cancelling it.
struct RecurringPauseSelection: Equatable {
    private(set) var pausedIDs: Set<UUID> = []

    func isPaused(_ id: UUID) -> Bool { pausedIDs.contains(id) }

    /// The value shown by an "included" toggle: on = the charge keeps running.
    func isIncluded(_ id: UUID) -> Bool { !pausedIDs.contains(id) }

    mutating func setIncluded(_ included: Bool, for id: UUID) {
        if included {
            pausedIDs.remove(id)
        } else {
            pausedIDs.insert(id)
        }
    }

    func pausedMonthlySpend(in items: [RecurringTransaction]) -> Double {
        items
            .filter { pausedIDs.contains($0.id) && $0.category.countsAsSpending }
            .reduce(0) { $0 + $1.monthlyAmount }
    }
}
