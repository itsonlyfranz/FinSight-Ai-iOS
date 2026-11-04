import XCTest
import SwiftData
@testable import FinSightAI

@MainActor
final class Phase6SystemTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }
    private func date(_ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }
    private func snapshot(spent: Decimal = 0, due: [SystemSnapshot.Due] = []) -> SystemSnapshot {
        SystemSnapshot(date: date(4), currency: "USD", spent: spent, budget: 100,
            topCategory: "Food", due: due,
            budgets: [BudgetStatusLine(category: .dining, limit: 100, spent: spent)], insights: [])
    }
    func testBudgetThresholdBoundariesAndStableIDs() {
        XCTAssertFalse(NudgePlanner.plan(snapshot: snapshot(spent: 79), calendar: calendar).contains { $0.id.hasPrefix("budget-") })
        let eighty = NudgePlanner.plan(snapshot: snapshot(spent: 80), calendar: calendar).filter { $0.id.hasPrefix("budget-") }
        XCTAssertEqual(eighty.count, 1)
        XCTAssertTrue(eighty[0].id.hasSuffix("-80"))
        XCTAssertEqual(eighty[0].id, NudgePlanner.plan(snapshot: snapshot(spent: 99), calendar: calendar).first { $0.id.hasPrefix("budget-") }?.id)
        XCTAssertTrue(NudgePlanner.plan(snapshot: snapshot(spent: 100), calendar: calendar).contains { $0.id.hasSuffix("-100") })
    }
    func testRecurringDatesAndWeeklyDigest() {
        let due = [SystemSnapshot.Due(id: "past", merchant: "Past", date: date(3)),
                   SystemSnapshot.Due(id: "next", merchant: "Next", date: date(6))]
        let plan = NudgePlanner.plan(snapshot: snapshot(due: due), calendar: calendar)
        XCTAssertEqual(plan.filter { $0.id.hasPrefix("due-") }.count, 1)
        XCTAssertEqual(plan.first { $0.id.hasPrefix("due-") }?.date, date(6, hour: 9))
        let digest = plan.first { $0.id.hasPrefix("digest-") }!
        XCTAssertEqual(calendar.component(.weekday, from: digest.date), 2)
        XCTAssertEqual(calendar.component(.hour, from: digest.date), 9)
        XCTAssertTrue(plan.allSatisfy { $0.date > date(4) })
    }
    func testRefreshStopsAtMidnightAndProgressClamps() {
        let late = date(4, hour: 23).addingTimeInterval(50 * 60)
        XCTAssertEqual(SystemSnapshot.nextRefresh(after: late, calendar: calendar), date(5, hour: 0))
        XCTAssertEqual(snapshot(spent: 150).progress, 1)
        XCTAssertEqual(snapshot(spent: -1).progress, 0)
    }
    func testIntentRejectsInvalidInputAndPreservesDecimal() throws {
        for value in [Double.nan, .infinity, -1, 0] {
            XCTAssertThrowsError(try ExpenseIntentService.validate(amount: value, merchant: "Cafe"))
        }
        XCTAssertThrowsError(try ExpenseIntentService.validate(amount: 1, merchant: " \n"))
        XCTAssertEqual(try ExpenseIntentService.validate(amount: 12.34, merchant: "Cafe"), Decimal(string: "12.34"))
    }
    func testNotificationPlanCapsRequestsBelowSystemLimit() {
        let due = (0..<100).map { SystemSnapshot.Due(id: String($0), merchant: "Bill", date: date(6)) }
        XCTAssertEqual(NudgePlanner.plan(snapshot: snapshot(due: due), calendar: calendar).count, 60)
    }
    func testStoreMigrationPreservesSidecarsAndDoesNotOverwriteSharedLedger() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("legacy.store")
        for suffix in ["", "-wal", "-shm"] { try Data("original".utf8).write(to: URL(fileURLWithPath: legacy.path + suffix)) }
        let group = root.appendingPathComponent("group")
        XCTAssertThrowsError(try SharedStore.prepare(groupURL: group, legacyURL: legacy, allowMigration: false))
        let shared = try SharedStore.prepare(groupURL: group, legacyURL: legacy, allowMigration: true)
        for suffix in ["", "-wal", "-shm"] {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: shared.path + suffix)), Data("original".utf8))
        }
        try Data("changed".utf8).write(to: legacy)
        XCTAssertEqual(try SharedStore.prepare(groupURL: group, legacyURL: legacy, allowMigration: false), shared)
        XCTAssertEqual(try Data(contentsOf: shared), Data("original".utf8))
    }

    func testPaidRecurringAdvancesToNextMonth() {
        let bill = RecurringExpenseRecord(merchantName: "Phone", amount: 50, category: .bills, expectedDay: 6, isActive: true, note: "")
        let entry = LedgerEntry(amount: 50, category: .bills, merchant: "Phone", date: date(3))
        let next = SystemSnapshot.upcoming(recurring: [bill], entries: [entry], now: date(4), calendar: calendar)
        XCTAssertEqual(calendar.component(.month, from: next[0].date), 12)
        bill.isActive = false
        XCTAssertTrue(SystemSnapshot.upcoming(recurring: [bill], entries: [], now: date(4), calendar: calendar).isEmpty)
    }

    func testSnapshotReadsPersistedExpenseAndExcludesIncomeAndFutureSpending() throws {
        let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        context.insert(TransactionRecord(amount: 12.34, merchantName: "Cafe", category: .dining, date: date(3), note: ""))
        context.insert(TransactionRecord(amount: 1000, kind: .income, merchantName: "Pay", category: .other, date: date(3), note: ""))
        context.insert(TransactionRecord(amount: 80, merchantName: "Future", category: .shopping, date: date(8), note: ""))
        try context.save()
        let value = try SystemSnapshot.load(now: date(4), container: container)
        XCTAssertEqual(value.spent, Decimal(string: "12.34"))
        XCTAssertEqual(value.topCategory, SpendingCategory.dining.title)
        XCTAssertEqual(value.budget, 0)
    }

    func testControlRequestsExpenseEditor() async throws {
        ExpenseNavigation.shared.requested = false
        _ = try await OpenExpenseControlIntent().perform()
        XCTAssertTrue(ExpenseNavigation.shared.requested)
        ExpenseNavigation.shared.requested = false
    }

    func testIntentServicePersistsExpenseAndRejectsInvalidWrite() throws {
        let container = try AppStoreSchema.makeContainer(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        try ExpenseIntentService.log(amount: 12.34, merchant: " Cafe ", in: context, date: date(3))
        XCTAssertThrowsError(try ExpenseIntentService.log(amount: -1, merchant: "Invalid", in: context))
        let records = try ModelContext(container).fetch(FetchDescriptor<TransactionRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.amount, Decimal(string: "12.34"))
        XCTAssertEqual(records.first?.merchantName, "Cafe")
        XCTAssertEqual(records.first?.kind, .expense)
    }

    func testDetectedRecurringDueAndPausedManualOverride() {
        let entries = (1...3).map { offset in
            LedgerEntry(amount: 50, category: .bills, merchant: "Phone",
                date: calendar.date(byAdding: .month, value: -offset, to: date(6))!)
        }
        let detected = SystemSnapshot.upcoming(recurring: [], entries: entries, now: date(4), calendar: calendar)
        XCTAssertEqual(detected.count, 1)
        XCTAssertTrue(detected[0].id.hasPrefix("detected-"))
        let paused = RecurringExpenseRecord(merchantName: "Phone", amount: 50, category: .bills, expectedDay: 6, isActive: false, note: "")
        XCTAssertTrue(SystemSnapshot.upcoming(recurring: [paused], entries: entries, now: date(4), calendar: calendar).isEmpty)
    }

}
