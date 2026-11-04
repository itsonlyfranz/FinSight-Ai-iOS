import Foundation

/// A cut applied to one category's everyday (non-recurring) monthly spending.
struct CategoryCut: Codable, Equatable, Hashable, Sendable {
    var category: SpendingCategory
    /// Whole percent of the category's baseline to cut, 0…100.
    var percent: Int
}

/// Everything the user can change in the what-if: the inputs only, never results. A scenario is
/// re-evaluated against the current baseline, so a saved one stays up to date as spending changes.
struct SimulationScenario: Codable, Equatable, Sendable {
    /// A "month" of daily saving, matching how the recurring and run-rate maths count a month.
    static let daysPerMonth = 30
    static let minimumHorizonMonths = 12
    static let maximumHorizonMonths = 60
    static let maximumAnnualYieldPercent = Decimal(20)
    /// The 4.5% a typical high-yield savings account paid when the plan was written.
    static let defaultAnnualYieldPercent = Decimal(string: "4.5", locale: Locale(identifier: "en_US_POSIX"))!

    var cuts: [CategoryCut]
    var dailySavings: Decimal
    /// Recurring charges the user switched off in this scenario.
    var pausedRecurringIDs: Set<UUID>
    /// Annual percentage yield on the saved money, e.g. 4.5 for 4.5%.
    var annualYieldPercent: Decimal
    /// Savings already set aside that the projection grows from.
    var startingBalance: Decimal
    var horizonMonths: Int

    init(
        cuts: [CategoryCut] = [],
        dailySavings: Decimal = 0,
        pausedRecurringIDs: Set<UUID> = [],
        annualYieldPercent: Decimal = SimulationScenario.defaultAnnualYieldPercent,
        startingBalance: Decimal = 0,
        horizonMonths: Int = SimulationScenario.minimumHorizonMonths
    ) {
        self.cuts = cuts
        self.dailySavings = dailySavings
        self.pausedRecurringIDs = pausedRecurringIDs
        self.annualYieldPercent = annualYieldPercent
        self.startingBalance = startingBalance
        self.horizonMonths = horizonMonths
    }

    // Tolerant decoding: a scenario saved by an older build still opens after fields are added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cuts: try container.decodeIfPresent([CategoryCut].self, forKey: .cuts) ?? [],
            dailySavings: try container.decodeIfPresent(Decimal.self, forKey: .dailySavings) ?? 0,
            pausedRecurringIDs: try container.decodeIfPresent(Set<UUID>.self, forKey: .pausedRecurringIDs) ?? [],
            annualYieldPercent: try container.decodeIfPresent(Decimal.self, forKey: .annualYieldPercent)
                ?? SimulationScenario.defaultAnnualYieldPercent,
            startingBalance: try container.decodeIfPresent(Decimal.self, forKey: .startingBalance) ?? 0,
            horizonMonths: try container.decodeIfPresent(Int.self, forKey: .horizonMonths)
                ?? SimulationScenario.minimumHorizonMonths
        )
    }

    func cutPercent(for category: SpendingCategory) -> Int {
        cuts.first { $0.category == category }?.percent ?? 0
    }

    /// Sets a category's cut; 0 removes it so the scenario only lists real changes.
    mutating func setCut(_ percent: Int, for category: SpendingCategory) {
        cuts.removeAll { $0.category == category }
        let clamped = min(max(percent, 0), 100)
        if clamped > 0, category.countsAsSpending {
            cuts.append(CategoryCut(category: category, percent: clamped))
        }
    }

    mutating func setRecurring(_ id: UUID, included: Bool) {
        if included {
            pausedRecurringIDs.remove(id)
        } else {
            pausedRecurringIDs.insert(id)
        }
    }

    /// The same scenario with every value forced into its valid range: one cut per spending
    /// category within 0…100%, no negative money, a yield of 0…20% and a 12…60 month horizon.
    var normalized: SimulationScenario {
        var seen = Set<SpendingCategory>()
        let cleanCuts = cuts.compactMap { cut -> CategoryCut? in
            guard cut.category.countsAsSpending, seen.insert(cut.category).inserted else { return nil }
            let percent = min(max(cut.percent, 0), 100)
            return percent > 0 ? CategoryCut(category: cut.category, percent: percent) : nil
        }
        return SimulationScenario(
            cuts: cleanCuts,
            dailySavings: max(0, dailySavings),
            pausedRecurringIDs: pausedRecurringIDs,
            annualYieldPercent: min(max(0, annualYieldPercent), Self.maximumAnnualYieldPercent),
            startingBalance: max(0, startingBalance),
            horizonMonths: min(max(horizonMonths, Self.minimumHorizonMonths), Self.maximumHorizonMonths)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case cuts, dailySavings, pausedRecurringIDs, annualYieldPercent, startingBalance, horizonMonths
    }
}

/// An unfinished savings goal as the simulator sees it (a plain value, so the maths stays pure).
struct SimulationGoal: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let targetAmount: Decimal
    let savedAmount: Decimal
    let targetDate: Date?
    /// What the goal already receives each month without this scenario (Phase 2's pace).
    let monthlyPace: Decimal

    init(
        id: UUID = UUID(),
        name: String,
        targetAmount: Decimal,
        savedAmount: Decimal = 0,
        targetDate: Date? = nil,
        monthlyPace: Decimal = 0
    ) {
        self.id = id
        self.name = name
        self.targetAmount = targetAmount
        self.savedAmount = savedAmount
        self.targetDate = targetDate
        self.monthlyPace = monthlyPace
    }

    var remaining: Decimal { max(0, targetAmount - savedAmount) }
}
