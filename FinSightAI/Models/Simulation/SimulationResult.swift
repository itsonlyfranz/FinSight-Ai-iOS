import Foundation

/// What one category's cut frees up each month.
struct CategorySaving: Identifiable, Equatable, Sendable {
    let category: SpendingCategory
    /// The category's everyday monthly spending the cut applies to.
    let monthlyBaseline: Decimal
    let percent: Int
    let saved: Decimal

    var id: SpendingCategory { category }
}

/// The projected savings balance at the end of one month.
struct ProjectionPoint: Identifiable, Equatable, Sendable {
    /// Months from now; 0 is today's starting balance.
    let month: Int
    let date: Date
    /// Balance with the yield compounded.
    let balance: Decimal
    /// What was put in without any yield: starting balance plus deposits.
    let contributed: Decimal
    /// The likely range around `balance`; nil when no spending history supports one.
    let lower: Decimal?
    let upper: Decimal?

    var id: Int { month }
    var interest: Decimal { balance - contributed }
}

/// Where a goal stands against this scenario.
struct GoalCountdown: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case reached
        /// Neither the goal's own pace nor the scenario saves anything toward it.
        case noPace
        case onTrack
        /// Funded after its target date.
        case behind
    }

    let id: UUID
    let name: String
    let targetAmount: Decimal
    let remaining: Decimal
    let targetDate: Date?
    /// Months to fund the goal at its own pace, without this scenario; nil when that never happens.
    let currentMonths: Int?
    /// Months with this scenario's savings added to the pace; nil when it never happens.
    let planMonths: Int?
    let fundedBy: Date?
    let status: Status

    /// How many months sooner the scenario funds the goal than the current pace (never negative).
    var monthsSooner: Int? {
        guard let planMonths else { return nil }
        guard let currentMonths else { return planMonths }
        return max(0, currentMonths - planMonths)
    }
}

struct SimulationResult: Equatable, Sendable {
    /// Total freed each month: category cuts + paused recurring + daily savings.
    let monthlySavings: Decimal
    let categorySavings: [CategorySaving]
    let pausedRecurringSavings: Decimal
    let pausedRecurringNames: [String]
    let dailySavingsPerMonth: Decimal
    /// Month 0 through the scenario's horizon.
    let timeline: [ProjectionPoint]
    let goals: [GoalCountdown]
    /// Whether the timeline carries a likely range.
    let hasUncertaintyBand: Bool

    static let empty = SimulationResult(
        monthlySavings: 0, categorySavings: [], pausedRecurringSavings: 0, pausedRecurringNames: [],
        dailySavingsPerMonth: 0, timeline: [], goals: [], hasUncertaintyBand: false
    )

    func point(atMonth month: Int) -> ProjectionPoint? {
        timeline.first { $0.month == month }
    }

    /// The 3-, 6- and 12-month markers.
    var milestones: [ProjectionPoint] {
        ForwardSimulator.milestoneMonths.compactMap { point(atMonth: $0) }
    }

    var threeMonths: Decimal { point(atMonth: 3)?.balance ?? 0 }
    var sixMonths: Decimal { point(atMonth: 6)?.balance ?? 0 }
    var twelveMonths: Decimal { point(atMonth: 12)?.balance ?? 0 }

    var hasSavings: Bool { monthlySavings > 0 }
}
