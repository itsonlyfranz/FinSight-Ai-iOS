import Foundation

struct SimulationInput: Equatable {
    /// Estimated full-month spending (see `MonthlyRunRate`), including recurring charges.
    var monthlyRunRate: Double
    /// Monthly total of all active recurring charges (already part of `monthlyRunRate`).
    var recurringMonthlySpend: Double = 0
    var dailySavings: Double
    var reductionPercent: Double
    var savingsGoal: Double
    /// Part of `recurringMonthlySpend` the user has paused in the simulator.
    var pausedRecurringMonthlySpend: Double = 0
}

struct SimulationProjection: Equatable {
    let monthlySavings: Double
    let projectedSavingsThreeMonths: Double
    let projectedSavingsSixMonths: Double
    let projectedSavingsTwelveMonths: Double
    let monthsToGoal: Int?
}
