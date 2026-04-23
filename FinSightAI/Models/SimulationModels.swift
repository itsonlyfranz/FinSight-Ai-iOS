import Foundation

struct SimulationInput: Equatable {
    var currentMonthlySpending: Double
    var dailySavings: Double
    var reductionPercent: Double
    var savingsGoal: Double
}

struct SimulationProjection: Equatable {
    let monthlySavings: Double
    let projectedSavingsThreeMonths: Double
    let projectedSavingsSixMonths: Double
    let projectedSavingsTwelveMonths: Double
    let monthsToGoal: Int?
}
