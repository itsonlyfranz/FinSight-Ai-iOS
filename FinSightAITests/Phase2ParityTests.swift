import SwiftData
import XCTest
@testable import FinSightAI

/// Phase 2: budgets, income gauge, savings goals, filtering, CSV export and settings.
@MainActor
final class Phase2ParityTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    override func tearDown() {
        CurrencyFormatter.setSelectedCurrencyCode(nil)
        super.tearDown()
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? Date()
    }

    private func dec(_ text: String) -> Decimal { Decimal(string: text)! }

    private func expense(_ amount: String, _ category: SpendingCategory, _ on: Date, merchant: String = "Shop", note: String = "") -> TransactionRecord {
        TransactionRecord(amount: dec(amount), merchantName: merchant, category: category, date: on, note: note)
    }

    // MARK: - Budget progress

    func testBudgetProgressSumsOnlyThisMonthsSpendInTheCategory() {
        let june = date(2025, 6, 15)
        let budgets = [Budget(category: .groceries, monthlyAmount: 500)]
        let transactions = [
            expense("120.10", .groceries, date(2025, 6, 1, hour: 0)),
            expense("79.90", .groceries, date(2025, 6, 30, hour: 23)),
            expense("300", .groceries, date(2025, 5, 31, hour: 23)),   // previous month
            expense("300", .groceries, date(2025, 7, 1, hour: 0)),     // next month
            expense("999", .dining, date(2025, 6, 10)),                // other category
            TransactionRecord(amount: 50, kind: .income, merchantName: "Refund", category: .groceries, date: date(2025, 6, 5)),
            TransactionRecord(amount: 50, kind: .transfer, merchantName: "Move", category: .groceries, date: date(2025, 6, 5))
        ]

        let progress = BudgetCalculator.progress(budgets: budgets, transactions: transactions, month: june, calendar: calendar)

        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress[0].spent, 200)
        XCTAssertEqual(progress[0].limit, 500)
        XCTAssertEqual(progress[0].remaining, 300)
        XCTAssertEqual(progress[0].fractionUsed, 0.4, accuracy: 1e-9)
        XCTAssertEqual(progress[0].status, .onTrack)
    }

    func testBudgetStatusThresholds() {
        func status(_ spent: String) -> BudgetStatus {
            BudgetProgress(category: .dining, baseLimit: 100, carriedOver: 0, spent: dec(spent)).status
        }
        XCTAssertEqual(status("0"), .onTrack)
        XCTAssertEqual(status("79.99"), .onTrack)
        XCTAssertEqual(status("80"), .nearLimit)
        XCTAssertEqual(status("100"), .nearLimit, "exactly on the limit is not yet over")
        XCTAssertEqual(status("100.01"), .overBudget)
    }

    func testOverBudgetFractionIsUncappedButProgressValueIsClamped() {
        let item = BudgetProgress(category: .dining, baseLimit: 100, carriedOver: 0, spent: 150)
        XCTAssertEqual(item.fractionUsed, 1.5, accuracy: 1e-9)
        XCTAssertEqual(item.progressValue, 1)
        XCTAssertEqual(item.remaining, -50)
    }

    func testZeroLimitBudgetCountsAsUsedOnlyWhenSomethingWasSpent() {
        XCTAssertEqual(BudgetProgress(category: .dining, baseLimit: 0, carriedOver: 0, spent: 0).fractionUsed, 0)
        XCTAssertEqual(BudgetProgress(category: .dining, baseLimit: 0, carriedOver: 0, spent: 5).status, .overBudget)
    }

    func testBudgetMathIsExactInDecimal() {
        let june = date(2025, 6, 15)
        let budgets = [Budget(category: .other, monthlyAmount: 1)]
        let transactions = (0..<10).map { _ in expense("0.1", .other, june) }
        let progress = BudgetCalculator.progress(budgets: budgets, transactions: transactions, month: june, calendar: calendar)
        XCTAssertEqual(progress[0].spent, 1)
        XCTAssertEqual(progress[0].remaining, 0)
        XCTAssertEqual(progress[0].status, .nearLimit)
    }

    func testSavingsBudgetsAreIgnoredAndResultsSortMostUsedFirst() {
        let june = date(2025, 6, 15)
        let budgets = [
            Budget(category: .groceries, monthlyAmount: 100),
            Budget(category: .dining, monthlyAmount: 100),
            Budget(category: .savings, monthlyAmount: 100)
        ]
        let transactions = [expense("30", .groceries, june), expense("90", .dining, june), expense("500", .savings, june)]
        let progress = BudgetCalculator.progress(budgets: budgets, transactions: transactions, month: june, calendar: calendar)
        XCTAssertEqual(progress.map(\.category), [.dining, .groceries])
        XCTAssertEqual(BudgetCalculator.totalLimit(progress), 200)
        XCTAssertEqual(BudgetCalculator.totalSpent(progress), 120)
    }

    func testRolloverCarriesUnspentBudgetFromEarlierMonths() {
        let created = date(2025, 4, 10)
        let budget = Budget(category: .groceries, monthlyAmount: 100, rolloverEnabled: true, createdAt: created)
        let transactions = [
            expense("60", .groceries, date(2025, 4, 20)),   // April: 40 unspent
            expense("130", .groceries, date(2025, 5, 3)),   // May: overspent, carries nothing
            expense("25", .groceries, date(2025, 6, 2))     // June spend
        ]
        let progress = BudgetCalculator.progress(budgets: [budget], transactions: transactions, month: date(2025, 6, 15), calendar: calendar)
        XCTAssertEqual(progress[0].carriedOver, 40)
        XCTAssertEqual(progress[0].limit, 140)
        XCTAssertEqual(progress[0].remaining, 115)
    }

    func testRolloverDisabledCarriesNothing() {
        let budget = Budget(category: .groceries, monthlyAmount: 100, rolloverEnabled: false, createdAt: date(2025, 1, 1))
        let progress = BudgetCalculator.progress(budgets: [budget], transactions: [], month: date(2025, 6, 15), calendar: calendar)
        XCTAssertEqual(progress[0].carriedOver, 0)
        XCTAssertEqual(progress[0].limit, 100)
    }

    func testRolloverIsCappedAtTwelveMonths() {
        let budget = Budget(category: .groceries, monthlyAmount: 10, rolloverEnabled: true, createdAt: date(2020, 1, 1))
        let progress = BudgetCalculator.progress(budgets: [budget], transactions: [], month: date(2025, 6, 15), calendar: calendar)
        XCTAssertEqual(progress[0].carriedOver, 120)
    }

    // MARK: - Income gauge

    func testIncomeGaugeCombinesSourcesAndLoggedIncome() {
        let june = date(2025, 6, 15)
        let sources = [
            IncomeSource(name: "Salary", monthlyAmount: 3000),
            IncomeSource(name: "Old job", monthlyAmount: 900, isActive: false)
        ]
        let transactions = [
            TransactionRecord(amount: 200, kind: .income, merchantName: "Bonus", category: .other, date: date(2025, 6, 3)),
            TransactionRecord(amount: 777, kind: .income, merchantName: "Last month", category: .other, date: date(2025, 5, 30)),
            expense("640", .bills, date(2025, 6, 4)),
            expense("160", .savings, date(2025, 6, 5))   // savings are not spending
        ]
        let gauge = IncomeCalculator.gauge(sources: sources, transactions: transactions, month: june, calendar: calendar)
        XCTAssertEqual(gauge.income, 3200)
        XCTAssertEqual(gauge.spent, 640)
        XCTAssertEqual(gauge.fractionSpent, 0.2, accuracy: 1e-9)
        XCTAssertEqual(gauge.buffer, 2560)
        XCTAssertFalse(gauge.isOverspent)
    }

    func testIncomeGaugeHandlesOverspendingAndNoIncome() {
        let over = IncomeGauge(income: 1000, spent: 1250)
        XCTAssertEqual(over.fractionSpent, 1.25, accuracy: 1e-9)
        XCTAssertEqual(over.gaugeValue, 1)
        XCTAssertEqual(over.buffer, -250)
        XCTAssertTrue(over.isOverspent)

        let none = IncomeGauge(income: 0, spent: 100)
        XCTAssertFalse(none.hasIncome)
        XCTAssertEqual(none.fractionSpent, 0)
        XCTAssertFalse(none.isOverspent)
    }

    // MARK: - Savings goals

    func testMonthsToReachRoundsUp() {
        XCTAssertEqual(GoalCalculator.monthsToReach(remaining: 1000, monthlyPace: 250), 4)
        XCTAssertEqual(GoalCalculator.monthsToReach(remaining: 1001, monthlyPace: 250), 5)
        XCTAssertEqual(GoalCalculator.monthsToReach(remaining: dec("0.01"), monthlyPace: 1000), 1)
        XCTAssertEqual(GoalCalculator.monthsToReach(remaining: 1000, monthlyPace: 3), 334)
    }

    func testMonthsToReachEdgeCases() {
        XCTAssertEqual(GoalCalculator.monthsToReach(remaining: 0, monthlyPace: 0), 0, "nothing left needs no pace")
        XCTAssertEqual(GoalCalculator.monthsToReach(remaining: -5, monthlyPace: 10), 0)
        XCTAssertNil(GoalCalculator.monthsToReach(remaining: 100, monthlyPace: 0))
        XCTAssertNil(GoalCalculator.monthsToReach(remaining: 100, monthlyPace: -20))
    }

    func testProjectionGivesFundedByDate() {
        let now = date(2025, 1, 31)
        let projection = GoalCalculator.projection(
            target: 1000, saved: 400, targetDate: nil, monthlyPace: 250, now: now, calendar: calendar
        )
        XCTAssertEqual(projection.remaining, 600)
        XCTAssertEqual(projection.monthsToReach, 3)
        XCTAssertEqual(projection.fundedBy, calendar.date(byAdding: .month, value: 3, to: now))
        XCTAssertEqual(calendar.component(.month, from: projection.fundedBy!), 4)
        XCTAssertNil(projection.requiredMonthly)
    }

    func testProjectionReachedAndNoPace() {
        let reached = GoalCalculator.projection(target: 500, saved: 500, targetDate: nil, monthlyPace: 0, now: date(2025, 1, 1), calendar: calendar)
        XCTAssertEqual(reached.outlook, .reached)
        XCTAssertNil(reached.fundedBy)

        let stalled = GoalCalculator.projection(target: 500, saved: 100, targetDate: nil, monthlyPace: 0, now: date(2025, 1, 1), calendar: calendar)
        XCTAssertEqual(stalled.outlook, .noPace)
        XCTAssertNil(stalled.monthsToReach)
    }

    func testRequiredMonthlyAndBehindTargetDate() {
        let now = date(2025, 1, 1)
        let target = date(2025, 7, 1)
        let projection = GoalCalculator.projection(
            target: 1200, saved: 0, targetDate: target, monthlyPace: 100, now: now, calendar: calendar
        )
        XCTAssertEqual(projection.requiredMonthly, 200, "1200 over 6 months")
        XCTAssertEqual(projection.monthsToReach, 12)
        XCTAssertTrue(projection.isBehindTargetDate(target))

        let onPace = GoalCalculator.projection(
            target: 1200, saved: 0, targetDate: target, monthlyPace: 200, now: now, calendar: calendar
        )
        XCTAssertFalse(onPace.isBehindTargetDate(target))
    }

    func testRequiredMonthlyIsNilForPastDatesOrFinishedGoals() {
        let now = date(2025, 6, 1)
        XCTAssertNil(GoalCalculator.requiredMonthly(remaining: 100, targetDate: date(2025, 5, 1), now: now, calendar: calendar))
        XCTAssertNil(GoalCalculator.requiredMonthly(remaining: 0, targetDate: date(2026, 5, 1), now: now, calendar: calendar))
        XCTAssertNil(GoalCalculator.requiredMonthly(remaining: 100, targetDate: nil, now: now, calendar: calendar))
        // Part months count as whole months: 1 month + 10 days → 2 months.
        XCTAssertEqual(GoalCalculator.requiredMonthly(remaining: 100, targetDate: date(2025, 7, 11), now: now, calendar: calendar), 50)
    }

    func testOwnPaceUsesNetRecentContributions() {
        let now = date(2025, 6, 30)
        let goal = SavingsGoal(name: "Trip", targetAmount: 5000)
        XCTAssertNil(GoalCalculator.ownPace(for: goal, now: now, calendar: calendar))

        goal.contribute(400, on: date(2025, 5, 10))
        goal.contribute(200, on: date(2025, 6, 10))
        goal.contribute(-100, on: date(2025, 6, 11))
        goal.contribute(10_000, on: date(2024, 1, 1))   // outside the 3-month window
        XCTAssertEqual(GoalCalculator.ownPace(for: goal, now: now, calendar: calendar), 500 / 3)
        XCTAssertEqual(goal.savedAmount, 10_500)

        let withdrawn = SavingsGoal(name: "Spent it", targetAmount: 100)
        withdrawn.contribute(-50, on: date(2025, 6, 1))
        XCTAssertNil(GoalCalculator.ownPace(for: withdrawn, now: now, calendar: calendar))
    }

    func testSurplusShareSplitsAcrossUnfinishedGoals() {
        XCTAssertEqual(GoalCalculator.surplusShare(monthlyIncome: 3000, monthlySpending: 2000, unfinishedGoals: 4), 250)
        XCTAssertEqual(GoalCalculator.surplusShare(monthlyIncome: 1000, monthlySpending: 2000, unfinishedGoals: 2), 0)
        XCTAssertEqual(GoalCalculator.surplusShare(monthlyIncome: 3000, monthlySpending: 0, unfinishedGoals: 0), 0)
    }

    func testGoalProgressAndContributionsStayInSync() {
        let goal = SavingsGoal(name: "Laptop", targetAmount: 2000, savedAmount: 500)
        XCTAssertEqual(goal.progress, 0.25, accuracy: 1e-9)
        goal.contribute(dec("1500.50"))
        XCTAssertEqual(goal.savedAmount, dec("2000.50"))
        XCTAssertTrue(goal.isReached)
        XCTAssertEqual(goal.progress, 1)
        XCTAssertEqual(goal.contributions?.count, 1)
    }

    // MARK: - Filtering

    func testCategoryChipsFilterUnionOfSelectedCategories() {
        let transactions = [
            expense("1", .groceries, date(2025, 6, 1), merchant: "A"),
            expense("1", .dining, date(2025, 6, 1), merchant: "B"),
            expense("1", .travel, date(2025, 6, 1), merchant: "C")
        ]
        var filter = TransactionFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertEqual(filter.apply(to: transactions).count, 3)

        filter.toggle(.groceries)
        filter.toggle(.travel)
        XCTAssertEqual(filter.apply(to: transactions).map(\.merchantName), ["A", "C"])
        filter.toggle(.travel)
        XCTAssertEqual(filter.apply(to: transactions).map(\.merchantName), ["A"])
        filter.reset()
        XCTAssertFalse(filter.isActive)
    }

    func testMerchantSearchIsCaseAndDiacriticInsensitiveAndTrimmed() {
        let transactions = [
            expense("1", .dining, date(2025, 6, 1), merchant: "Café Rosé", note: ""),
            expense("1", .groceries, date(2025, 6, 1), merchant: "Landers", note: "weekly restock"),
            expense("1", .transport, date(2025, 6, 1), merchant: "Grab", note: "")
        ]
        var filter = TransactionFilter(searchText: "  CAFE ")
        XCTAssertEqual(filter.apply(to: transactions).map(\.merchantName), ["Café Rosé"])
        filter.searchText = "restock"
        XCTAssertEqual(filter.apply(to: transactions).map(\.merchantName), ["Landers"], "notes are searched too")
        filter.searchText = "   "
        XCTAssertFalse(filter.isActive)
        filter.searchText = "zzz"
        XCTAssertTrue(filter.apply(to: transactions).isEmpty)
    }

    func testChipsAndSearchCombine() {
        let transactions = [
            expense("1", .groceries, date(2025, 6, 1), merchant: "Market"),
            expense("1", .dining, date(2025, 6, 1), merchant: "Market Cafe")
        ]
        let filter = TransactionFilter(categories: [.dining], searchText: "market")
        XCTAssertEqual(filter.apply(to: transactions).map(\.merchantName), ["Market Cafe"])
    }

    // MARK: - CSV escaping (RFC 4180)

    func testPlainFieldsAreNotQuoted() {
        XCTAssertEqual(CSV.escape("Landers"), "Landers")
        XCTAssertEqual(CSV.escape(""), "")
        XCTAssertEqual(CSV.escape("12.50"), "12.50")
        XCTAssertEqual(CSV.escape("héllo ☕"), "héllo ☕")
    }

    func testFieldsWithSpecialCharactersAreQuotedAndQuotesDoubled() {
        XCTAssertEqual(CSV.escape("Smith, John"), "\"Smith, John\"")
        XCTAssertEqual(CSV.escape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(CSV.escape("line1\nline2"), "\"line1\nline2\"")
        XCTAssertEqual(CSV.escape("a\r\nb"), "\"a\r\nb\"")
        XCTAssertEqual(CSV.escape("a\rb"), "\"a\rb\"")
        XCTAssertEqual(CSV.escape("\""), "\"\"\"\"")
        XCTAssertEqual(CSV.escape(" padded"), "\" padded\"")
    }

    func testRecordsUseCRLFAndEndWithOne() {
        let text = CSV.document(header: ["a", "b"], rows: [["1", "x,y"], ["2", ""]])
        XCTAssertEqual(text, "a,b\r\n1,\"x,y\"\r\n2,\r\n")
    }

    func testParserHandlesQuotedCommasQuotesAndNewlines() {
        let parsed = CSV.parse("a,\"b,c\",\"d\"\"e\"\r\n\"multi\nline\",,x")
        XCTAssertEqual(parsed, [["a", "b,c", "d\"e"], ["multi\nline", "", "x"]])
        XCTAssertEqual(CSV.parse("a\nb\n"), [["a"], ["b"]])
        XCTAssertEqual(CSV.parse(""), [])
    }

    func testParserRejectsMalformedInput() {
        XCTAssertNil(CSV.parse("\"unterminated"))
        XCTAssertNil(CSV.parse("\"closed\"junk"))
        XCTAssertNil(CSV.parse("ab\"cd"))
    }

    func testEscapeAndParseRoundTripNastyFields() {
        let nasty = [
            "", " ", "plain", "comma,comma", "quote\"quote", "\"\"", "nl\nnl", "crlf\r\nx", "cr\rx",
            "  leading and trailing  ", "tab\t", "emoji 🍕, \"yes\"", "日本語,テスト", ",", "\"", "a,\"b\"\nc"
        ]
        let rows = stride(from: 0, to: nasty.count - 2, by: 3).map { Array(nasty[$0..<$0 + 3]) }
        let text = CSV.document(header: ["x", "y", "z"], rows: rows)
        let parsed = CSV.parse(text)
        XCTAssertEqual(parsed, [["x", "y", "z"]] + rows)
    }

    func testTransactionExportRoundTripsThroughTheParser() throws {
        let rows = [
            TransactionExportRow(TransactionRecord(
                amount: dec("1234.5"), merchantName: "Smith, \"Bob\" & Co", category: .shopping,
                date: date(2025, 6, 20), note: "line one\nline two, with comma"
            )),
            TransactionExportRow(TransactionRecord(
                amount: dec("0.07"), kind: .income, merchantName: "Interest", category: .other,
                date: date(2025, 6, 21), note: ""
            )),
            TransactionExportRow(TransactionRecord(
                amount: 2500, kind: .transfer, merchantName: "BPI", category: .savings,
                date: date(2025, 1, 2), note: "Emergency fund"
            ))
        ]
        let text = TransactionCSVExporter.csv(rows: rows, calendar: calendar)
        let parsed = try XCTUnwrap(CSV.parse(text))

        XCTAssertEqual(parsed[0], ["Date", "Type", "Merchant", "Category", "Amount", "Note"])
        XCTAssertEqual(parsed.count, 4)
        // Newest first.
        XCTAssertEqual(parsed[1], ["2025-06-21", "income", "Interest", "other", "0.07", ""])
        XCTAssertEqual(parsed[2], ["2025-06-20", "expense", "Smith, \"Bob\" & Co", "shopping", "1234.5", "line one\nline two, with comma"])
        XCTAssertEqual(parsed[3], ["2025-01-02", "transfer", "BPI", "savings", "2500", "Emergency fund"])

        // The amount text parses back to the exact value.
        XCTAssertEqual(Decimal(string: parsed[2][4], locale: Locale(identifier: "en_US_POSIX")), dec("1234.5"))
    }

    func testAmountStringsAreLocaleIndependentAndExact() {
        XCTAssertEqual(TransactionCSVExporter.amountString(dec("1234567.89")), "1234567.89")
        XCTAssertEqual(TransactionCSVExporter.amountString(100), "100")
        XCTAssertEqual(TransactionCSVExporter.amountString(dec("0.1")), "0.1")
        XCTAssertEqual(TransactionCSVExporter.amountString(dec("19.9900")), "19.99")
        XCTAssertEqual(TransactionCSVExporter.amountString(0), "0")
    }

    func testExportFileNameAndEmptyLedger() {
        XCTAssertEqual(TransactionCSVExporter.fileName(now: date(2025, 6, 7), calendar: calendar), "FinSight-transactions-2025-06-07.csv")
        XCTAssertEqual(TransactionCSVExporter.csv(rows: [], calendar: calendar), "Date,Type,Merchant,Category,Amount,Note\r\n")
    }

    func testCSVExportTransferableWritesAFileOnDisk() throws {
        let export = TransactionsCSVExport(transactions: [expense("5", .dining, date(2025, 6, 1), merchant: "A,B")], now: date(2025, 6, 2))
        XCTAssertEqual(export.fileName, "FinSight-transactions-2025-06-02.csv")
        XCTAssertEqual(export.rows.count, 1)
    }

    // MARK: - Settings, currency and AppContext

    private func makeContext() throws -> AppContext {
        let environment = try AppEnvironment.make(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try environment.appContext.bootstrap()
        return environment.appContext
    }

    func testBootstrapStartsEmptyWithDeviceCurrency() throws {
        let context = try makeContext()
        XCTAssertTrue(context.hasNoData)
        XCTAssertTrue(context.incomeSources.isEmpty)
        XCTAssertTrue(context.budgets.isEmpty)
        XCTAssertTrue(context.savingsGoals.isEmpty)
        XCTAssertEqual(context.currencyCode, Locale.current.currency?.identifier ?? "USD")
    }

    func testChangingCurrencyChangesFormattingNotAmounts() throws {
        let context = try makeContext()
        try context.setCurrency(code: "eur")
        XCTAssertEqual(context.currencyCode, "EUR")
        XCTAssertEqual(CurrencyFormatter.currencyCode, "EUR")
        XCTAssertTrue(CurrencyFormatter.string(from: dec("12.5"), locale: Locale(identifier: "en_US")).contains("$"), "an explicit locale still wins")
        XCTAssertTrue(CurrencyFormatter.string(from: dec("12.5")).contains("€"))
        XCTAssertTrue(CurrencyFormatter.string(from: 12.5).contains("€"))
    }

    func testIncomeSourceLifecycleUpdatesTheGauge() throws {
        let context = try makeContext()
        try context.saveIncomeSource(nil, name: "  Salary ", monthlyAmount: dec("2500.50"))
        XCTAssertEqual(context.incomeSources.map(\.name), ["Salary"])
        XCTAssertEqual(context.monthlyRecurringIncome, dec("2500.50"))
        XCTAssertEqual(context.incomeGauge.income, dec("2500.50"))

        let source = try XCTUnwrap(context.incomeSources.first)
        try context.setIncomeSource(source, active: false)
        XCTAssertEqual(context.incomeGauge.income, 0)
        try context.setIncomeSource(source, active: true)
        try context.saveIncomeSource(source, name: "Salary", monthlyAmount: 3000)
        XCTAssertEqual(context.incomeGauge.income, 3000)
        try context.delete(source)
        XCTAssertTrue(context.incomeSources.isEmpty)
    }

    func testIncomeValidation() throws {
        let context = try makeContext()
        XCTAssertThrowsError(try context.saveIncomeSource(nil, name: "", monthlyAmount: 100)) {
            XCTAssertEqual($0 as? PlanningError, .missingName)
        }
        XCTAssertThrowsError(try context.saveIncomeSource(nil, name: "Pay", monthlyAmount: 0))
        XCTAssertThrowsError(try context.saveIncomeSource(nil, name: "Pay", monthlyAmount: nil))
        XCTAssertThrowsError(try context.saveIncomeSource(nil, name: "Pay", monthlyAmount: -5))
        XCTAssertTrue(context.incomeSources.isEmpty)
    }

    func testBudgetsAreUniquePerCategoryAndRemovedByZero() throws {
        let context = try makeContext()
        try context.setBudget(category: .dining, monthlyAmount: 300)
        try context.setBudget(category: .dining, monthlyAmount: 450, rollover: true)
        XCTAssertEqual(context.budgets.count, 1)
        XCTAssertEqual(context.budget(for: .dining)?.monthlyAmount, 450)
        XCTAssertEqual(context.budget(for: .dining)?.rolloverEnabled, true)
        XCTAssertEqual(context.progress(for: .dining)?.limit, 450)

        try context.setBudget(category: .savings, monthlyAmount: 100)
        XCTAssertNil(context.budget(for: .savings), "savings can't be budgeted")

        try context.setBudget(category: .dining, monthlyAmount: nil)
        XCTAssertTrue(context.budgets.isEmpty)
        XCTAssertTrue(context.budgetProgress.isEmpty)
        XCTAssertThrowsError(try context.setBudget(category: .dining, monthlyAmount: -1))
    }

    func testBudgetProgressFollowsNewTransactions() throws {
        let context = try makeContext()
        try context.setBudget(category: .groceries, monthlyAmount: 100)
        var draft = TransactionDraft()
        draft.amountText = "85"
        draft.merchantName = "Market"
        draft.category = .groceries
        draft.date = .now
        context.activeDraft = draft
        try context.saveDraft()

        let progress = try XCTUnwrap(context.progress(for: .groceries))
        XCTAssertEqual(progress.spent, 85)
        XCTAssertEqual(progress.status, .nearLimit)
    }

    func testIncomeTransactionsCountTowardTheGaugeNotSpending() throws {
        let context = try makeContext()
        var draft = TransactionDraft()
        draft.kind = .income
        draft.amountText = "1000"
        draft.merchantName = "Freelance"
        draft.category = .shopping
        context.activeDraft = draft
        try context.saveDraft()

        XCTAssertEqual(context.transactions.first?.kind, .income)
        XCTAssertEqual(context.transactions.first?.category, .other, "income carries no spending category")
        XCTAssertEqual(context.incomeGauge.income, 1000)
        XCTAssertEqual(context.incomeGauge.spent, 0)
        XCTAssertEqual(context.monthlySummary.totalSpent, 0)
    }

    func testGoalLifecycleAndProjection() throws {
        let context = try makeContext()
        try context.saveIncomeSource(nil, name: "Salary", monthlyAmount: 2000)
        try context.saveGoal(nil, name: " Trip ", targetAmount: 1000, savedAmount: 100, targetDate: nil)
        let goal = try XCTUnwrap(context.savingsGoals.first)
        XCTAssertEqual(goal.name, "Trip")
        XCTAssertEqual(goal.savedAmount, 100)

        // No spending history yet → the whole income is surplus, shared with the only goal.
        let first = context.goalProjection(for: goal)
        XCTAssertEqual(first.monthlyPace, context.goalSurplusShare)
        XCTAssertNotNil(first.monthsToReach)

        try context.contribute(to: goal, amount: 900)
        XCTAssertTrue(goal.isReached)
        XCTAssertEqual(context.goalProjection(for: goal).outlook, .reached)

        try context.contribute(to: goal, amount: 2000, withdraw: true)
        XCTAssertEqual(goal.savedAmount, 0, "withdrawals never push the total below zero")

        XCTAssertThrowsError(try context.contribute(to: goal, amount: 0))
        XCTAssertThrowsError(try context.saveGoal(nil, name: "", targetAmount: 10, savedAmount: 0, targetDate: nil))
        XCTAssertThrowsError(try context.saveGoal(nil, name: "X", targetAmount: nil, savedAmount: 0, targetDate: nil))

        try context.delete(goal)
        XCTAssertTrue(context.savingsGoals.isEmpty)
    }

    func testSampleDataIsOptInAndFillsPlanningOnlyOnce() throws {
        let context = try makeContext()
        XCTAssertTrue(context.transactions.isEmpty)
        try context.loadSampleData()
        XCTAssertFalse(context.transactions.isEmpty)
        XCTAssertEqual(context.incomeSources.count, 1)
        XCTAssertFalse(context.budgets.isEmpty)
        XCTAssertEqual(context.savingsGoals.count, 1)

        let counts = (context.transactions.count, context.incomeSources.count, context.budgets.count, context.savingsGoals.count)
        try context.loadSampleData()
        XCTAssertEqual(counts.0, context.transactions.count)
        XCTAssertEqual(counts.1, context.incomeSources.count)
        XCTAssertEqual(counts.2, context.budgets.count)
        XCTAssertEqual(counts.3, context.savingsGoals.count)
    }

    func testFirstWeekdayIsNormalizedAndPersisted() throws {
        let context = try makeContext()
        try context.setFirstWeekday(2)
        XCTAssertEqual(context.settings?.firstWeekday, 2)
        try context.setFirstWeekday(42)
        XCTAssertEqual(context.settings?.firstWeekday, 1)
    }
}
