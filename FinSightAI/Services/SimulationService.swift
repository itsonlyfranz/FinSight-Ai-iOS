import Foundation

protocol SimulationService {
    func simulate(
        baseline: RunRateBaseline,
        scenario: SimulationScenario,
        goals: [SimulationGoal],
        now: Date,
        calendar: Calendar
    ) -> SimulationResult
}

/// Runs scenarios through the pure `ForwardSimulator`.
struct DefaultSimulationService: SimulationService {
    func simulate(
        baseline: RunRateBaseline,
        scenario: SimulationScenario,
        goals: [SimulationGoal],
        now: Date,
        calendar: Calendar
    ) -> SimulationResult {
        ForwardSimulator.simulate(baseline: baseline, scenario: scenario, goals: goals, now: now, calendar: calendar)
    }
}

extension RunRateBaseline {
    /// The active recurring charges that count as spending, as exact `Decimal` amounts.
    static func recurringCharges(from summary: RecurringSummary) -> [RecurringCharge] {
        summary.spendingItems.map {
            RecurringCharge(
                id: $0.id,
                name: $0.merchantName,
                category: $0.category,
                monthlyAmount: Money.decimal(fromLegacy: $0.monthlyAmount)
            )
        }
    }
}
