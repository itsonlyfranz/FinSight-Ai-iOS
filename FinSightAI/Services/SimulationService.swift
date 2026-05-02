import Foundation

protocol SimulationService {
    func project(input: SimulationInput) -> SimulationProjection
}

struct DefaultSimulationService: SimulationService {
    func project(input: SimulationInput) -> SimulationProjection {
        let reductionSavings = input.currentMonthlySpending * (input.reductionPercent / 100)
        let monthlySavings = max(0, input.dailySavings * 30 + reductionSavings + input.disabledRecurringMonthlySpend)
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
