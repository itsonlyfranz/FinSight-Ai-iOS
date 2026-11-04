import SwiftData
import XCTest
@testable import FinSightAI

/// Phase 5: the forward simulator. The first group mirrors the seven tests in the Android app's
/// `ForwardSimulatorEngineTest` as behavioural specs; the rest cover the run-rate baseline, the
/// uncertainty band, scenario comparison and persistence, and the AI explanation.
@MainActor
final class Phase5SimulationTests: XCTestCase {
    private typealias F = InsightFixtures
    private let calendar = InsightFixtures.utc
    private let now = InsightFixtures.date(2024, 3, 15)

    // MARK: - Helpers

    /// A baseline with the given everyday monthly spending per category.
    private func baseline(
        _ amounts: [(SpendingCategory, Decimal)] = [],
        recurring: [RecurringCharge] = [],
        volatility: [SpendingCategory: Decimal] = [:]
    ) -> RunRateBaseline {
        RunRateBaseline(
            lines: amounts.map { RunRateBaseline.Line(category: $0.0, discretionary: $0.1, recurring: 0) },
            excludedOneOffs: [],
            recurringCharges: recurring,
            categoryVolatility: volatility
        )
    }

    private func simulate(
        _ baseline: RunRateBaseline,
        _ scenario: SimulationScenario,
        goals: [SimulationGoal] = []
    ) -> SimulationResult {
        ForwardSimulator.simulate(baseline: baseline, scenario: scenario, goals: goals, now: now, calendar: calendar)
    }

    private func scenario(cuts: [(SpendingCategory, Int)] = [], yield: Decimal = SimulationScenario.defaultAnnualYieldPercent) -> SimulationScenario {
        var scenario = SimulationScenario(annualYieldPercent: yield)
        for (category, percent) in cuts { scenario.setCut(percent, for: category) }
        return scenario
    }

    private func dec(_ text: String) -> Decimal { F.dec(text) }

    // MARK: - Android spec 1: no reductions produces zero savings

    func testNoCutsProduceZeroSavingsAndZeroProjections() {
        let result = simulate(baseline([(.dining, 280), (.shopping, 420)]), scenario())

        XCTAssertEqual(result.monthlySavings, 0)
        XCTAssertEqual(result.threeMonths, 0)
        XCTAssertEqual(result.sixMonths, 0)
        XCTAssertEqual(result.twelveMonths, 0)
        XCTAssertFalse(result.hasSavings)
        XCTAssertTrue(SimulationSummaryText.content(scenario: scenario(), result: result).summary.contains("Nothing is being saved"))
    }

    // MARK: - Android spec 2: a category cut compounds above the straight-line total

    func testCategoryCutSavesItsShareAndCompoundsAboveLinear() {
        let result = simulate(baseline([(.dining, 280)]), scenario(cuts: [(.dining, 20)]))

        XCTAssertEqual(result.monthlySavings, 56)
        XCTAssertGreaterThan(result.threeMonths, 168, "3-month projection should include compound yield")
        XCTAssertGreaterThan(result.sixMonths, 336)
        XCTAssertGreaterThan(result.twelveMonths, 672)
        XCTAssertEqual(result.categorySavings.map(\.category), [.dining])
        XCTAssertEqual(result.categorySavings.first?.saved, 56)
    }

    // MARK: - Android spec 3: another category

    func testShoppingCutSavesItsShare() {
        let result = simulate(baseline([(.shopping, 400)]), scenario(cuts: [(.shopping, 15)]))
        XCTAssertEqual(result.monthlySavings, 60)
    }

    // MARK: - Android spec 4: combined cuts add up

    func testCombinedCutsAddUp() {
        let result = simulate(baseline([(.dining, 280), (.shopping, 420)]), scenario(cuts: [(.dining, 20), (.shopping, 15)]))

        XCTAssertEqual(result.monthlySavings, 119)
        XCTAssertGreaterThan(result.twelveMonths, 1_428, "12M projection should exceed 12 × 119")
        XCTAssertEqual(result.categorySavings.map(\.category), [.shopping, .dining], "largest saving first")
    }

    // MARK: - Android spec 5: invalid compounding inputs

    func testCompoundedBalanceReturnsZeroForInvalidInputs() {
        XCTAssertEqual(ForwardSimulator.compoundedBalance(monthlyDeposit: -10, months: 12, annualYieldPercent: 4.5), 0)
        XCTAssertEqual(ForwardSimulator.compoundedBalance(monthlyDeposit: 100, months: 0, annualYieldPercent: 4.5), 0)
        XCTAssertEqual(ForwardSimulator.compoundedBalance(monthlyDeposit: 100, months: -3, annualYieldPercent: 4.5), 0)
        XCTAssertEqual(ForwardSimulator.compoundedBalance(startingBalance: 500, monthlyDeposit: 100, months: 0, annualYieldPercent: 4.5), 500)
    }

    // MARK: - Android spec 6: months to goal with freed cash flow

    func testMonthsToReachRoundsUpWithAndWithoutFreedCashflow() {
        // Target 5,400, saved 2,100: 3,300 to go. At 300 a month that is 11 months; with 178 freed, 478 a month is 7.
        XCTAssertEqual(ForwardSimulator.monthsToReach(target: 5_400, saved: 2_100, monthlyDeposit: 300, annualYieldPercent: 0), 11)
        XCTAssertEqual(ForwardSimulator.monthsToReach(target: 5_400, saved: 2_100, monthlyDeposit: 478, annualYieldPercent: 0), 7)
        XCTAssertEqual(ForwardSimulator.monthsToReach(target: 5_400, saved: 5_400, monthlyDeposit: 0, annualYieldPercent: 0), 0)
        XCTAssertNil(ForwardSimulator.monthsToReach(target: 5_400, saved: 2_100, monthlyDeposit: 0, annualYieldPercent: 0))
        XCTAssertNil(ForwardSimulator.monthsToReach(target: 5_400, saved: 0, monthlyDeposit: 0, annualYieldPercent: 4.5))
    }

    func testYieldShortensTheCountdown() {
        let flat = ForwardSimulator.monthsToReach(target: 100_000, saved: 20_000, monthlyDeposit: 2_000, annualYieldPercent: 0)
        let earning = ForwardSimulator.monthsToReach(target: 100_000, saved: 20_000, monthlyDeposit: 2_000, annualYieldPercent: 8)
        XCTAssertEqual(flat, 40)
        XCTAssertNotNil(earning)
        XCTAssertLessThan(earning ?? .max, 40)
    }

    func testCountdownGivesUpAfterFiftyYears() {
        XCTAssertNil(ForwardSimulator.monthsToReach(target: 1_000_000_000, saved: 0, monthlyDeposit: 1, annualYieldPercent: 0))
        XCTAssertNil(ForwardSimulator.monthsToReach(target: 1_000_000_000, saved: 0, monthlyDeposit: 1, annualYieldPercent: 4.5))
    }

    // MARK: - Android spec 7: goal projections with dynamic status and dates

    func testGoalCountdownsFollowTheScenario() {
        let emergency = SimulationGoal(name: "Emergency fund", targetAmount: 5_400, savedAmount: 2_100, monthlyPace: 300)
        let rig = SimulationGoal(name: "Dev rig", targetAmount: 3_200, savedAmount: 800, monthlyPace: 300)
        let done = SimulationGoal(name: "Trip", targetAmount: 1_000, savedAmount: 1_000, monthlyPace: 300)

        // 20% of 890 frees 178 a month.
        let result = simulate(baseline([(.dining, 890)]), scenario(cuts: [(.dining, 20)], yield: 0), goals: [emergency, rig, done])

        XCTAssertEqual(result.monthlySavings, 178)
        XCTAssertEqual(result.goals.count, 3)
        let emergencyCountdown = result.goals[0]
        XCTAssertEqual(emergencyCountdown.currentMonths, 11)
        XCTAssertEqual(emergencyCountdown.planMonths, 7)
        XCTAssertEqual(emergencyCountdown.monthsSooner, 4)
        XCTAssertEqual(emergencyCountdown.fundedBy, calendar.date(byAdding: .month, value: 7, to: now))
        XCTAssertEqual(emergencyCountdown.status, .onTrack)
        // 2,400 to go ÷ 478 = 5.02, so 6 months.
        XCTAssertEqual(result.goals[1].planMonths, 6)
        XCTAssertEqual(result.goals[2].status, .reached)
        XCTAssertEqual(result.goals[2].planMonths, 0)
    }

    func testGoalIsBehindWhenFundedAfterItsTargetDate() {
        let deadline = calendar.date(byAdding: .month, value: 3, to: now)
        let goal = SimulationGoal(name: "Car", targetAmount: 12_000, savedAmount: 0, targetDate: deadline, monthlyPace: 500)
        let result = simulate(baseline(), scenario(yield: 0), goals: [goal])
        XCTAssertEqual(result.goals.first?.status, .behind)
        XCTAssertEqual(result.goals.first?.planMonths, 24)
    }

    func testGoalWithNoPaceAndNoSavingsIsNoPace() {
        let goal = SimulationGoal(name: "Boat", targetAmount: 12_000, monthlyPace: 0)
        let result = simulate(baseline(), scenario(), goals: [goal])
        XCTAssertEqual(result.goals.first?.status, .noPace)
        XCTAssertNil(result.goals.first?.planMonths)
        XCTAssertNil(result.goals.first?.fundedBy)
    }

    // MARK: - Compounding semantics

    func testCompoundingFollowsDepositThenInterest() {
        // 100 a month at 12% APY is 1% a month: month 1 = 100 × 1.01, month 2 = (101 + 100) × 1.01.
        let balances = ForwardSimulator.balances(startingBalance: 0, monthlyDeposit: 100, months: 2, annualYieldPercent: 12)
        XCTAssertEqual(balances, [0, 101, dec("203.01")])
        XCTAssertEqual(ForwardSimulator.compoundedBalance(monthlyDeposit: 100, months: 2, annualYieldPercent: 12), dec("203.01"))
    }

    func testStartingBalanceCompoundsToo() {
        // (1,000 + 100) × 1.01 = 1,111.
        XCTAssertEqual(ForwardSimulator.compoundedBalance(startingBalance: 1_000, monthlyDeposit: 100, months: 1, annualYieldPercent: 12), 1_111)
    }

    func testZeroYieldIsPlainSumAndNegativeYieldCountsAsZero() {
        XCTAssertEqual(ForwardSimulator.compoundedBalance(monthlyDeposit: 56, months: 12, annualYieldPercent: 0), 672)
        XCTAssertEqual(ForwardSimulator.compoundedBalance(monthlyDeposit: 56, months: 12, annualYieldPercent: -5), 672)
    }

    func testTimelineRunsFromTodayThroughTheHorizonWithInterestSplitOut() {
        var plan = scenario(cuts: [(.dining, 20)], yield: 12)
        plan.startingBalance = 1_000
        plan.horizonMonths = 24
        let result = simulate(baseline([(.dining, 280)]), plan)

        XCTAssertEqual(result.timeline.count, 25)
        XCTAssertEqual(result.timeline.first?.month, 0)
        XCTAssertEqual(result.timeline.first?.balance, 1_000)
        XCTAssertEqual(result.timeline.last?.month, 24)
        XCTAssertEqual(result.timeline[1].date, calendar.date(byAdding: .month, value: 1, to: now))
        XCTAssertEqual(result.timeline[12].contributed, 1_000 + 56 * 12)
        XCTAssertGreaterThan(result.timeline[12].interest, 0)
        XCTAssertEqual(result.milestones.map(\.month), [3, 6, 12])
    }

    func testDailySavingsCountThirtyDaysAndPausedChargesCountOnce() {
        let netflix = RecurringCharge(id: UUID(), name: "Netflix", category: .entertainment, monthlyAmount: dec("15.99"))
        var plan = scenario()
        plan.dailySavings = 10
        plan.setRecurring(netflix.id, included: false)
        let result = simulate(baseline(recurring: [netflix]), plan)

        XCTAssertEqual(result.dailySavingsPerMonth, 300)
        XCTAssertEqual(result.pausedRecurringSavings, dec("15.99"))
        XCTAssertEqual(result.pausedRecurringNames, ["Netflix"])
        XCTAssertEqual(result.monthlySavings, dec("315.99"))
    }

    func testCutsApplyOnlyToEverydaySpendingNotRecurring() {
        let rent = RecurringCharge(id: UUID(), name: "Rent", category: .bills, monthlyAmount: 1_000)
        let baseline = RunRateBaseline(
            lines: [RunRateBaseline.Line(category: .bills, discretionary: 200, recurring: 1_000)],
            excludedOneOffs: [], recurringCharges: [rent], categoryVolatility: [:]
        )
        let result = simulate(baseline, scenario(cuts: [(.bills, 50)]))
        XCTAssertEqual(result.monthlySavings, 100, "50% of the 200 everyday bills, not of the 1,000 rent")
    }

    // MARK: - Scenario value

    func testNormalizedClampsEveryInput() {
        let messy = SimulationScenario(
            cuts: [
                CategoryCut(category: .dining, percent: 250),
                CategoryCut(category: .dining, percent: 10),
                CategoryCut(category: .savings, percent: 30),
                CategoryCut(category: .travel, percent: -5)
            ],
            dailySavings: -20,
            annualYieldPercent: 99,
            startingBalance: -1,
            horizonMonths: 500
        ).normalized

        XCTAssertEqual(messy.cuts, [CategoryCut(category: .dining, percent: 100)])
        XCTAssertEqual(messy.dailySavings, 0)
        XCTAssertEqual(messy.annualYieldPercent, 20)
        XCTAssertEqual(messy.startingBalance, 0)
        XCTAssertEqual(messy.horizonMonths, 60)
        XCTAssertEqual(SimulationScenario(horizonMonths: 1).normalized.horizonMonths, 12)
    }

    func testSetCutRemovesZeroAndIgnoresSavings() {
        var plan = SimulationScenario()
        plan.setCut(20, for: .dining)
        plan.setCut(30, for: .savings)
        XCTAssertEqual(plan.cuts, [CategoryCut(category: .dining, percent: 20)])
        plan.setCut(0, for: .dining)
        XCTAssertTrue(plan.cuts.isEmpty)
    }

    func testScenarioRoundTripsThroughJSONAndToleratesMissingFields() throws {
        var plan = scenario(cuts: [(.dining, 20), (.shopping, 15)], yield: dec("3.75"))
        plan.dailySavings = dec("12.5")
        plan.startingBalance = dec("1234.56")
        plan.horizonMonths = 36
        plan.setRecurring(UUID(), included: false)

        let decoded = try JSONDecoder().decode(SimulationScenario.self, from: JSONEncoder().encode(plan))
        XCTAssertEqual(decoded, plan)

        let sparse = try JSONDecoder().decode(SimulationScenario.self, from: Data("{}".utf8))
        XCTAssertEqual(sparse, SimulationScenario())
    }

    // MARK: - Run-rate baseline (fixes D8)

    private func spend(_ amount: Decimal, _ category: SpendingCategory, on date: Date, kind: TransactionKind = .expense, id: UUID = UUID()) -> LedgerEntry {
        LedgerEntry(id: id, amount: amount, kind: kind, category: category, merchant: "", date: date)
    }

    private func makeBaseline(_ entries: [LedgerEntry], recurring: [RecurringCharge] = [], recurringIDs: Set<UUID> = []) -> RunRateBaseline {
        RunRateBaseline.make(entries: entries, recurring: recurring, recurringTransactionIDs: recurringIDs, now: now, calendar: calendar)
    }

    func testBaselineScalesRecentSpendingToAFullMonthPerCategory() {
        // 30 observed days (Feb 15 … Mar 15): totals are taken as they are.
        let entries = [
            spend(600, .groceries, on: F.date(2024, 2, 15)),
            spend(300, .dining, on: F.date(2024, 3, 1))
        ]
        let baseline = makeBaseline(entries)
        XCTAssertEqual(baseline.line(for: .groceries)?.discretionary, 600)
        XCTAssertEqual(baseline.line(for: .dining)?.discretionary, 300)
        XCTAssertEqual(baseline.monthlyTotal, 900)
        XCTAssertEqual(baseline.cuttableLines.map(\.category), [.groceries, .dining])

        // Only 3 observed days: floored at 7, then scaled to 30.
        let early = RunRateBaseline.make(
            entries: [spend(70, .dining, on: F.date(2024, 3, 13))], now: now, calendar: calendar
        )
        XCTAssertEqual(early.monthlyTotal, Decimal(70) / 7 * 30)
    }

    func testBaselineIgnoresOldTransfersIncomeAndSavings() {
        let entries = [
            spend(100, .dining, on: F.date(2024, 3, 1)),
            spend(5_000, .other, on: F.date(2024, 3, 1), kind: .income),
            spend(700, .other, on: F.date(2024, 3, 2), kind: .transfer),
            spend(9_999, .savings, on: F.date(2024, 3, 3)),
            spend(4_000, .travel, on: F.date(2023, 12, 1))
        ]
        let baseline = makeBaseline(entries)
        XCTAssertEqual(baseline.lines.map(\.category), [.dining])
        XCTAssertEqual(baseline.monthlyTotal, 100, "the ledger predates the window, so all 30 days were observed")
        XCTAssertTrue(baseline.excludedOneOffs.isEmpty)
    }

    func testBaselineIsNotScaledUpWhenTheLedgerPredatesTheWindow() {
        // The first purchase in the window is on Mar 1, but the ledger began in December with an
        // income entry, so the quiet first half of the window is real and not missing history.
        let purchase = spend(100, .dining, on: F.date(2024, 3, 1))
        let established = makeBaseline([spend(3_000, .other, on: F.date(2023, 12, 1), kind: .income), purchase])
        XCTAssertEqual(established.monthlyTotal, 100)

        // A ledger that genuinely starts inside the window is still scaled: Mar 1 … Mar 15 is 15 days.
        let newcomer = makeBaseline([spend(3_000, .other, on: F.date(2024, 3, 1), kind: .income), purchase])
        XCTAssertEqual(newcomer.monthlyTotal, 100 * 30 / 15)
    }

    func testBaselineLeavesOutOneOffPurchases() {
        var entries = (0..<5).map { spend(100, .groceries, on: F.date(2024, 3, 1 + $0 * 2)) }
        let laptop = spend(5_000, .shopping, on: F.date(2024, 3, 10))
        entries.append(laptop)
        let baseline = makeBaseline(entries)

        XCTAssertEqual(baseline.excludedOneOffs.map(\.id), [laptop.id])
        XCTAssertNil(baseline.line(for: .shopping), "a single big purchase is not a monthly habit")

        // One large shop in a category that has no other purchases is not a one-off.
        let grocer = makeBaseline(entries[0..<5].map { $0 } + [spend(450, .health, on: F.date(2024, 3, 10))])
        XCTAssertTrue(grocer.excludedOneOffs.isEmpty)
        XCTAssertEqual(grocer.line(for: .health)?.discretionary, 450 * 30 / 15)
        XCTAssertEqual(baseline.excludedOneOffTotal, 5_000)
        XCTAssertEqual(baseline.line(for: .groceries)?.discretionary, 500 * 30 / 15)
    }

    func testBaselineUsesTheCategorysOwnUsualSizeOnceItHasEnough() {
        let usual = (0..<4).map { spend(100, .groceries, on: F.date(2024, 3, 1 + $0)) }
        let big = spend(450, .groceries, on: F.date(2024, 3, 8))
        let baseline = makeBaseline(usual + [big])
        XCTAssertEqual(baseline.excludedOneOffs.map(\.id), [big.id], "4.5× the usual grocery trip")

        let ordinary = makeBaseline(usual + [spend(150, .groceries, on: F.date(2024, 3, 8))])
        XCTAssertTrue(ordinary.excludedOneOffs.isEmpty, "a 50% bigger trip is normal variation")
    }

    func testBaselineAddsRecurringChargesOnceAndSkipsTheirPayments() {
        let paymentID = UUID()
        let rent = RecurringCharge(id: UUID(), name: "Rent", category: .bills, monthlyAmount: 10_000)
        let entries = [
            spend(10_000, .bills, on: F.date(2024, 3, 3), id: paymentID),
            spend(70, .dining, on: F.date(2024, 3, 13))
        ]
        let baseline = makeBaseline(entries, recurring: [rent], recurringIDs: [paymentID])

        XCTAssertEqual(baseline.recurringTotal, 10_000)
        XCTAssertEqual(baseline.line(for: .bills)?.discretionary, 0)
        // The rent payment isn't counted as spending, but it still marks the ledger's start: Mar 3 … Mar 15.
        XCTAssertEqual(baseline.line(for: .dining)?.discretionary, dec("161.54"))
        XCTAssertEqual(baseline.monthlyTotal, 10_000 + dec("161.54"))
        XCTAssertEqual(baseline.cuttableLines.map(\.category), [.dining], "recurring charges are paused, not cut")
    }

    func testVolatilityIsPerCategoryAndNeedsThreeCompleteMonths() {
        func month(_ month: Int, _ amount: Decimal, _ category: SpendingCategory = .groceries) -> LedgerEntry {
            spend(amount, category, on: F.date(month > 3 ? 2023 : 2024, month, 10))
        }

        XCTAssertTrue(makeBaseline([month(1, 1_000), month(2, 1_200)]).categoryVolatility.isEmpty)
        XCTAssertFalse(makeBaseline([month(1, 1_000), month(2, 1_200)]).hasVolatilityHistory)

        // Months of 1,000 / 1,200 / 800 / 1,000: mean 1,000, sample standard deviation √(80,000 / 3).
        let history = [month(11, 1_000), month(12, 1_200), month(1, 800), month(2, 1_000)]
        let baseline = makeBaseline(history)
        XCTAssertEqual(baseline.categoryVolatility[.groceries]?.doubleValue ?? 0, (80_000.0 / 3).squareRoot(), accuracy: 0.01)

        // The current, incomplete month is not part of it.
        XCTAssertEqual(makeBaseline(history + [month(3, 9_000)]).categoryVolatility, baseline.categoryVolatility)

        // A month with no spending in a category counts as zero for that category: 0 / 600 / 0 / 0.
        let sparse = makeBaseline(history + [month(1, 600, .dining)])
        XCTAssertEqual(sparse.categoryVolatility[.dining]?.doubleValue ?? 0, 300, accuracy: 0.01)
    }

    // MARK: - Uncertainty band

    func testBandBracketsTheProjectionAndWidensWithTime() {
        // A 20% cut of a category that swings by 500 a month swings the savings by 100.
        let result = simulate(baseline([(.dining, 1_000)], volatility: [.dining: 500]), scenario(cuts: [(.dining, 20)]))

        XCTAssertTrue(result.hasUncertaintyBand)
        var previousWidth: Decimal = -1
        for point in result.timeline {
            let lower = point.lower ?? .greatestFiniteMagnitude
            let upper = point.upper ?? 0
            XCTAssertLessThanOrEqual(lower, point.balance)
            XCTAssertGreaterThanOrEqual(upper, point.balance)
            XCTAssertGreaterThanOrEqual(upper - lower, previousWidth)
            previousWidth = upper - lower
        }
        XCTAssertEqual(result.timeline[0].lower, result.timeline[0].balance, "no uncertainty about today")
        XCTAssertEqual(result.timeline[0].upper, result.timeline[0].balance)
        XCTAssertGreaterThan(previousWidth, 0)
    }

    func testBandWithoutYieldIsZTimesSigmaTimesRootMonths() {
        // No interest: the swings of independent months add in quadrature, so after 4 months the half-width is z·σ·√4.
        let result = simulate(baseline([(.dining, 1_000)], volatility: [.dining: 500]), scenario(cuts: [(.dining, 20)], yield: 0))
        let point = result.timeline[4]
        XCTAssertEqual(point.balance, 800)
        XCTAssertEqual(point.upper, 800 + dec("256.32"))
        XCTAssertEqual(point.lower, 800 - dec("256.32"))
    }

    func testBandNeverDropsBelowWhatSavingNothingWouldLeave() {
        // A cut of a very swingy category: the raw range would dip below the starting balance.
        var plan = scenario(cuts: [(.travel, 50)], yield: 0)
        plan.startingBalance = 1_000
        let result = simulate(baseline([(.travel, 300)], volatility: [.travel: 520]), plan)
        let point = result.timeline[3]
        XCTAssertEqual(point.balance, 1_450)
        XCTAssertEqual(point.lower, 1_000, "a cut can't save less than nothing")
        XCTAssertEqual(point.upper, 1_450 + dec("577.15"))
    }

    func testBandFollowsTheCutsNotTheWholeBudget() {
        let history: [SpendingCategory: Decimal] = [.dining: 500, .shopping: 1_000]
        let base = baseline([(.dining, 1_000), (.shopping, 1_000)], volatility: history)

        XCTAssertEqual(base.savingsVolatility(for: [CategoryCut(category: .dining, percent: 20)]), 100)
        // Independent swings add in quadrature: √(100² + 100²).
        XCTAssertEqual(
            base.savingsVolatility(for: [CategoryCut(category: .dining, percent: 20), CategoryCut(category: .shopping, percent: 10)]),
            dec("141.42")
        )
        XCTAssertEqual(base.savingsVolatility(for: []), 0)

        // Saving a fixed daily amount carries no spending risk, so the band has no width.
        var daily = SimulationScenario(dailySavings: 10)
        daily.annualYieldPercent = 0
        let result = simulate(base, daily)
        XCTAssertTrue(result.hasUncertaintyBand)
        XCTAssertEqual(result.timeline[12].lower, result.timeline[12].balance)
    }

    func testNoHistoryMeansNoBand() {
        let result = simulate(baseline([(.dining, 1_000)]), scenario(cuts: [(.dining, 20)]))
        XCTAssertFalse(result.hasUncertaintyBand)
        XCTAssertTrue(result.timeline.allSatisfy { $0.lower == nil && $0.upper == nil })
        XCTAssertNil(baseline().savingsVolatility(for: [CategoryCut(category: .dining, percent: 20)]))

        XCTAssertEqual(ForwardSimulator.halfWidth(month: 6, volatility: 0, growth: 1.003), 0)
    }

    // MARK: - Scenario comparison

    func testComparisonRanksByTwelveMonthBalance() {
        let base = baseline([(.dining, 1_000)])
        let small = ScenarioComparison.Entry(id: UUID(), name: "Small", result: simulate(base, scenario(cuts: [(.dining, 10)])))
        let big = ScenarioComparison.Entry(id: UUID(), name: "Big", result: simulate(base, scenario(cuts: [(.dining, 40)])))
        let comparison = ScenarioComparison.make([small, big])

        XCTAssertEqual(comparison.best?.name, "Big")
        XCTAssertEqual(comparison.rows.map(\.isBest), [false, true])
        XCTAssertEqual(comparison.rows[0].twelveMonthDelta, 0)
        XCTAssertEqual(comparison.rows[1].twelveMonthDelta, big.result.twelveMonths - small.result.twelveMonths)
        XCTAssertGreaterThan(comparison.rows[1].twelveMonthDelta, 0)
    }

    func testComparisonOfOneOrNoneHasNoWinner() {
        XCTAssertTrue(ScenarioComparison.make([]).rows.isEmpty)
        let only = ScenarioComparison.Entry(id: UUID(), name: "Only", result: .empty)
        XCTAssertNil(ScenarioComparison.make([only]).best)
    }

    func testComparisonLabelsKeepDuplicateNamesDistinctInTheTableAndWinner() {
        let base = baseline([(.dining, 1_000)])
        let working = ScenarioComparison.Entry(id: UUID(), name: "Current", result: simulate(base, scenario(cuts: [(.dining, 10)])))
        let saved = ScenarioComparison.Entry(id: UUID(), name: "Current", result: simulate(base, scenario(cuts: [(.dining, 40)])))
        let other = ScenarioComparison.Entry(id: UUID(), name: "Lean", result: simulate(base, scenario(cuts: [(.dining, 20)])))
        let comparison = ScenarioComparison.make([working, saved, other])

        XCTAssertEqual(comparison.rows.map(\.label), ["Current", "Current (2)", "Lean"])
        XCTAssertEqual(comparison.referenceLabel, "Current")
        XCTAssertEqual(comparison.bestLabel, "Current (2)")
    }

    // MARK: - Explanation text

    private func sampleResult() -> (SimulationScenario, RunRateBaseline, SimulationResult) {
        let goal = SimulationGoal(name: "Emergency fund", targetAmount: 90_000, savedAmount: 15_000, monthlyPace: 2_000)
        let base = baseline([(.dining, 3_000), (.shopping, 2_000)], volatility: [.dining: 1_000, .shopping: 1_000])
        let plan = scenario(cuts: [(.dining, 20), (.shopping, 10)])
        return (plan, base, ForwardSimulator.simulate(baseline: base, scenario: plan, goals: [goal], now: now, calendar: calendar))
    }

    func testFactsCarryTheFiguresTheModelMayQuote() {
        let (plan, base, result) = sampleResult()
        let facts = SimulationFacts.context(scenario: plan, baseline: base, result: result).facts

        for expected in [result.monthlySavings, result.threeMonths, result.sixMonths, result.twelveMonths, base.monthlyTotal] {
            XCTAssertTrue(
                FigureGrounding.numbers(in: facts).contains(expected.rounded(scale: 2)),
                "\(expected) should appear in the facts"
            )
        }
        XCTAssertTrue(facts.contains("Cut Dining by 20%"))
        XCTAssertTrue(facts.contains("Likely range"))
        XCTAssertTrue(facts.contains("Emergency fund"))
    }

    func testThePlainSummaryOnlyQuotesFiguresFromTheFacts() {
        let (plan, base, result) = sampleResult()
        let facts = SimulationFacts.context(scenario: plan, baseline: base, result: result).facts
        let markdown = SimulationSummaryText.content(scenario: plan, result: result).markdown

        XCTAssertTrue(markdown.contains("## Scenario Summary"))
        XCTAssertTrue(markdown.contains("## Tradeoff"))
        XCTAssertTrue(markdown.contains("## Recommended Next Step"))
        XCTAssertFalse(FigureGrounding.amounts(in: markdown).isEmpty)
        XCTAssertEqual(FigureGrounding.ungroundedAmounts(in: markdown, sources: [facts]), [])
    }

    func testGroundingCatchesAnInventedAmount() {
        let (plan, base, result) = sampleResult()
        let facts = SimulationFacts.context(scenario: plan, baseline: base, result: result).facts
        XCTAssertEqual(FigureGrounding.ungroundedAmounts(in: "You will save $12,345.67.", sources: [facts]), [dec("12345.67")])
    }

    func testNarrationMarkdownSkipsEmptySections() {
        let partial = SimulationNarrationContent(summary: "It grows.", tradeoff: "  ", nextSteps: [])
        XCTAssertEqual(partial.markdown, "## Scenario Summary\n\nIt grows.")

        let full = SimulationNarrationContent(summary: "A", tradeoff: "B", nextSteps: ["C", "", "D"])
        XCTAssertEqual(full.markdown, "## Scenario Summary\n\nA\n\n## Tradeoff\n\nB\n\n## Recommended Next Step\n\n- C\n- D")
        XCTAssertEqual(SimulationNarrationContent(summary: "", tradeoff: "", nextSteps: []).markdown, "")
    }

    func testFactsChangeWithTheScenario() {
        let base = baseline([(.dining, 1_000)])
        func facts(_ percent: Int) -> String {
            let plan = scenario(cuts: [(.dining, percent)])
            return SimulationFacts.context(scenario: plan, baseline: base, result: simulate(base, plan)).fingerprint
        }
        XCTAssertEqual(facts(10), facts(10))
        XCTAssertNotEqual(facts(10), facts(20))
    }

    // MARK: - AppContext: seeding, goals, AI states, saved scenarios

    private func makeContext(ai: AIInsightService = StubExplainer(.succeed)) throws -> (AppContext, ModelContext) {
        let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let modelContext = ModelContext(container)
        let context = AppContext(
            repository: SwiftDataTransactionRepository(modelContext: modelContext),
            recurringExpenseRepository: SwiftDataRecurringExpenseRepository(modelContext: modelContext),
            modelContext: modelContext,
            summaryService: DefaultSummaryService(),
            recurringSummaryService: DefaultRecurringSummaryService(),
            aiInsightService: ai,
            simulationService: DefaultSimulationService(),
            capabilityService: StaticCapabilityService(aiAvailability: .available)
        )
        try context.bootstrap()
        return (context, modelContext)
    }

    private func addExpense(_ context: AppContext, _ amount: String, _ category: SpendingCategory, daysAgo: Int = 1) throws {
        var draft = TransactionDraft()
        draft.locale = Locale(identifier: "en_US")
        draft.amountText = amount
        draft.merchantName = "Shop"
        draft.category = category
        draft.date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        context.activeDraft = draft
        try context.saveDraft()
    }

    func testSlidersAreSeededFromTheUsersLargestEverydayCategories() throws {
        let (context, _) = try makeContext()
        XCTAssertTrue(context.workingScenario.cuts.isEmpty, "nothing to seed from an empty ledger")
        XCTAssertFalse(context.isScenarioSeeded)

        try addExpense(context, "400", .groceries)
        try addExpense(context, "250", .dining)
        try addExpense(context, "90", .transport)
        try addExpense(context, "50", .health)

        XCTAssertTrue(context.isScenarioSeeded)
        XCTAssertEqual(Set(context.workingScenario.cuts.map(\.category)), [.groceries, .dining, .transport])
        XCTAssertTrue(context.workingScenario.cuts.allSatisfy { $0.percent == AppContext.seededCutPercent })
        XCTAssertEqual(context.runRateBaseline.cuttableLines.map(\.category), [.groceries, .dining, .transport, .health])

        // The user's edits survive new transactions.
        context.workingScenario.setCut(0, for: .groceries)
        try addExpense(context, "30", .travel)
        XCTAssertEqual(context.workingScenario.cutPercent(for: .groceries), 0)

        context.resetWorkingScenario()
        XCTAssertEqual(context.workingScenario.cutPercent(for: .groceries), AppContext.seededCutPercent)
    }

    func testSimulationGoalsUsePhaseTwoGoalsAndPace() throws {
        let (context, _) = try makeContext()
        try context.saveGoal(nil, name: "Emergency fund", targetAmount: 9_000, savedAmount: 1_000, targetDate: nil)
        try context.saveGoal(nil, name: "Done", targetAmount: 100, savedAmount: 100, targetDate: nil)

        let goals = context.simulationGoals()
        XCTAssertEqual(goals.map(\.name), ["Emergency fund"], "finished goals are left out")
        XCTAssertEqual(goals.first?.remaining, 8_000)

        let result = context.simulate(context.workingScenario)
        XCTAssertEqual(result.goals.map(\.name), ["Emergency fund"])
    }

    func testExplanationUsesTheStructuredSessionAndCachesPerScenario() async throws {
        let ai = StubExplainer(.succeed)
        let (context, _) = try makeContext(ai: ai)
        let plan = scenario(cuts: [(.dining, 20)])
        let base = baseline([(.dining, 1_000)])
        let narration = SimulationFacts.context(scenario: plan, baseline: base, result: simulate(base, plan))

        await context.loadSimulationExplanation(context: narration)
        guard case .available(let content) = context.simulatorExplanationState else { return XCTFail("expected an explanation") }
        XCTAssertEqual(content.value, StubExplainer.reply)
        XCTAssertEqual(ai.lastFacts, narration.facts, "the model is handed the facts built by code")

        await context.loadSimulationExplanation(context: narration)
        XCTAssertEqual(ai.calls, 1, "unchanged scenario is served from the cache")
    }

    func testUnavailableModelFallsBackWithItsReason() async throws {
        let (context, _) = try makeContext(ai: StubExplainer(.unavailable(.appleIntelligenceNotEnabled)))
        await context.loadSimulationExplanation(context: SimulationNarrationContext(facts: "x"))
        XCTAssertEqual(context.simulatorExplanationState, .modelUnavailable(.appleIntelligenceNotEnabled))
    }

    func testUngroundedExplanationIsHiddenInFavourOfThePlainSummary() async throws {
        let (context, _) = try makeContext(ai: StubExplainer(.fail(AIInsightError.ungroundedFigures)))
        await context.loadSimulationExplanation(context: SimulationNarrationContext(facts: "y"))
        guard case .unavailable(let message) = context.simulatorExplanationState else { return XCTFail("expected the fallback state") }
        XCTAssertEqual(message, AIInsightError.ungroundedFigures.errorDescription)
    }

    func testSavingNamedScenariosAndComparingThem() throws {
        let (context, modelContext) = try makeContext()
        try addExpense(context, "1000", .dining)
        context.workingScenario = scenario(cuts: [(.dining, 10)])
        let first = try context.saveWorkingScenario(named: "  Gentle  ")
        context.workingScenario = scenario(cuts: [(.dining, 50)])
        let second = try context.saveWorkingScenario(named: "Aggressive")

        XCTAssertEqual(first.name, "Gentle")
        XCTAssertEqual(Set(context.savedScenarios.map(\.name)), ["Gentle", "Aggressive"])
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<SavedScenarioRecord>()).count, 2)

        // Saving under an existing name (any case) updates it instead of duplicating.
        context.workingScenario = scenario(cuts: [(.dining, 20)])
        let again = try context.saveWorkingScenario(named: "gentle")
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(context.savedScenarios.count, 2)
        XCTAssertEqual(again.scenario?.cutPercent(for: .dining), 20)

        XCTAssertThrowsError(try context.saveWorkingScenario(named: "   "))

        // Loading puts a saved scenario back in the editor.
        context.workingScenario = SimulationScenario()
        XCTAssertTrue(context.loadScenario(second))
        XCTAssertEqual(context.workingScenario.cutPercent(for: .dining), 50)

        // The comparison re-runs each scenario against today's baseline, the edited one first.
        let comparison = context.scenarioComparison(including: [first.id, second.id])
        XCTAssertEqual(comparison.rows.map(\.entry.name), ["Current", "gentle", "Aggressive"], "re-saving adopts the new spelling")
        XCTAssertEqual(comparison.rows.first?.entry.id, AppContext.currentScenarioID)
        XCTAssertEqual(comparison.best?.name, "Current", "the 50% working scenario saves the most")
        XCTAssertGreaterThan(comparison.rows[0].entry.result.monthlySavings, comparison.rows[1].entry.result.monthlySavings)

        // Unknown ids are skipped and the number compared is capped.
        XCTAssertEqual(context.scenarioComparison(including: [UUID()]).rows.count, 1)
        XCTAssertLessThanOrEqual(
            context.scenarioComparison(including: Array(repeating: second.id, count: 10)).rows.count,
            AppContext.maximumComparedScenarios
        )

        try context.deleteScenario(first)
        XCTAssertEqual(context.savedScenarios.map(\.name), ["Aggressive"])
    }

    func testUnreadableSavedScenarioIsReportedNotFatal() throws {
        let (context, modelContext) = try makeContext()
        let record = SavedScenarioRecord(name: "Broken", scenario: SimulationScenario())
        record.scenarioData = Data("not json".utf8)
        modelContext.insert(record)
        try modelContext.save()
        try context.reloadScenarios()

        XCTAssertNil(record.scenario)
        XCTAssertFalse(context.loadScenario(record))
        XCTAssertEqual(context.scenarioComparison(including: [record.id]).rows.count, 1)
    }

    func testDuplicateScenarioRowsAreCollapsedKeepingTheNewest() throws {
        let (_, modelContext) = try makeContext()
        let id = UUID()
        modelContext.insert(SavedScenarioRecord(id: id, name: "Old", scenario: SimulationScenario(), updatedAt: F.date(2024, 1, 1)))
        modelContext.insert(SavedScenarioRecord(id: id, name: "New", scenario: SimulationScenario(), updatedAt: F.date(2024, 2, 1)))
        try modelContext.save()

        XCTAssertEqual(try StoreIntegrity.dedupe(in: modelContext), 1)
        XCTAssertEqual(try modelContext.fetch(FetchDescriptor<SavedScenarioRecord>()).map(\.name), ["New"])
    }

    // MARK: - V3 → V4 migration

    func testStoreWrittenAsSchemaV3OpensAtV4WithAllDataIntact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinSightV4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.sqlite")
        let transactionID = UUID()
        do {
            let v3 = Schema(FinSightSchemaV3.models)
            let container = try ModelContainer(for: v3, configurations: ModelConfiguration(schema: v3, url: url))
            let context = ModelContext(container)
            context.insert(FinSightSchemaV2.TransactionRecord(
                id: transactionID, amount: F.dec("19.99"), merchantName: "Netflix", category: .entertainment, date: F.date(2026, 10, 10)
            ))
            let goal = FinSightSchemaV2.SavingsGoal(name: "Emergency", targetAmount: 5000)
            context.insert(goal)
            goal.contribute(700)
            context.insert(FinSightSchemaV3.InsightStateRecord(insightID: "x", status: .dismissed))
            try context.save()
        }

        let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(schema: AppStoreSchema.schema, url: url))
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TransactionRecord>()).map(\.id), [transactionID])
        XCTAssertEqual(try context.fetch(FetchDescriptor<TransactionRecord>()).first?.amount, F.dec("19.99"))
        XCTAssertEqual(try context.fetch(FetchDescriptor<SavingsGoal>()).first?.savedAmount, 700)
        XCTAssertEqual(try context.fetch(FetchDescriptor<InsightStateRecord>()).count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SavedScenarioRecord>()).isEmpty)

        // The new table is usable straight away, and keeps its scenario across a reopen.
        context.insert(SavedScenarioRecord(name: "Plan", scenario: scenario(cuts: [(.dining, 20)])))
        try context.save()
        let reopened = ModelContext(try AppStoreSchema.makeContainer(configuration: ModelConfiguration(schema: AppStoreSchema.schema, url: url)))
        let stored = try reopened.fetch(FetchDescriptor<SavedScenarioRecord>())
        XCTAssertEqual(stored.first?.scenario?.cutPercent(for: .dining), 20)
    }

    func testSchemaV4AddsOnlyTheScenarioModel() {
        XCTAssertEqual(FinSightSchemaV4.models.count, FinSightSchemaV3.models.count + 1)
        XCTAssertEqual(FinSightSchemaV4.versionIdentifier, Schema.Version(4, 0, 0))
        XCTAssertTrue(FinSightMigrationPlan.schemas.contains { ObjectIdentifier($0) == ObjectIdentifier(FinSightSchemaV4.self) })
    }
}

/// A canned explainer for the simulator tests; records what it was asked.
private final class StubExplainer: AIInsightService, @unchecked Sendable {
    enum Behavior {
        case succeed
        case unavailable(AIUnavailableReason)
        case fail(AIInsightError)
    }

    static let reply = "## Scenario Summary\n\nExplained."
    let providerIdentifier = "stub"
    private let behavior: Behavior
    private let lock = NSLock()
    private var _calls = 0
    private var _lastFacts: String?

    init(_ behavior: Behavior) { self.behavior = behavior }

    var calls: Int { lock.withLock { _calls } }
    var lastFacts: String? { lock.withLock { _lastFacts } }

    func generateInsights(
        from context: NarrationContext,
        onUpdate: (@Sendable ([GeneratedInsightCard]) async -> Void)?
    ) async throws -> GeneratedInsightPayload {
        throw AIInsightError.unavailable("not used")
    }

    func explainSimulation(
        context: SimulationNarrationContext,
        onUpdate: (@Sendable (String) async -> Void)?
    ) async throws -> GeneratedSimulationExplanation {
        lock.withLock {
            _calls += 1
            _lastFacts = context.facts
        }
        switch behavior {
        case .succeed:
            await onUpdate?(Self.reply)
            return GeneratedSimulationExplanation(markdown: Self.reply, providerIdentifier: providerIdentifier)
        case .unavailable(let reason):
            throw AIInsightError.modelUnavailable(reason)
        case .fail(let error):
            throw error
        }
    }
}
