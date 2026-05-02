import Foundation
import SwiftData

@MainActor
protocol RecurringExpenseRepository {
    func fetchAllRecurringExpenses() throws -> [RecurringExpenseRecord]
    func addRecurringExpense(from draft: RecurringExpenseDraft) throws
    func updateRecurringExpense(_ record: RecurringExpenseRecord, from draft: RecurringExpenseDraft) throws
    func deleteRecurringExpense(_ record: RecurringExpenseRecord) throws
}

@MainActor
final class SwiftDataRecurringExpenseRepository: RecurringExpenseRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchAllRecurringExpenses() throws -> [RecurringExpenseRecord] {
        let descriptor = FetchDescriptor<RecurringExpenseRecord>()
        return try modelContext.fetch(descriptor).sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive {
                return lhs.isActive && !rhs.isActive
            }
            if lhs.expectedDay != rhs.expectedDay {
                return lhs.expectedDay < rhs.expectedDay
            }
            return lhs.merchantName.localizedCaseInsensitiveCompare(rhs.merchantName) == .orderedAscending
        }
    }

    func addRecurringExpense(from draft: RecurringExpenseDraft) throws {
        guard let amount = draft.amount else {
            throw ValidationError.invalidAmount
        }

        let record = RecurringExpenseRecord(
            merchantName: draft.merchantName.trimmingCharacters(in: .whitespacesAndNewlines),
            amount: amount,
            category: draft.category,
            expectedDay: draft.expectedDay,
            isActive: draft.isActive,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.insert(record)
        try modelContext.save()
    }

    func updateRecurringExpense(_ record: RecurringExpenseRecord, from draft: RecurringExpenseDraft) throws {
        guard let amount = draft.amount else {
            throw ValidationError.invalidAmount
        }

        record.merchantName = draft.merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        record.amount = amount
        record.category = draft.category
        record.expectedDay = min(max(draft.expectedDay, 1), 31)
        record.isActive = draft.isActive
        record.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        record.updatedAt = .now
        try modelContext.save()
    }

    func deleteRecurringExpense(_ record: RecurringExpenseRecord) throws {
        modelContext.delete(record)
        try modelContext.save()
    }
}

protocol RecurringSummaryService {
    func makeSummary(
        recurringExpenses: [RecurringExpenseRecord],
        transactions: [TransactionRecord],
        now: Date
    ) -> RecurringSummary
}

struct DefaultRecurringSummaryService: RecurringSummaryService {
    private let calendar: Calendar
    private let amountTolerance: Double
    private let gracePeriodDays: Int

    init(
        calendar: Calendar = .current,
        amountTolerance: Double = 0.10,
        gracePeriodDays: Int = 3
    ) {
        self.calendar = calendar
        self.amountTolerance = amountTolerance
        self.gracePeriodDays = gracePeriodDays
    }

    func makeSummary(
        recurringExpenses: [RecurringExpenseRecord],
        transactions: [TransactionRecord],
        now: Date = .now
    ) -> RecurringSummary {
        let activeExpenses = recurringExpenses.filter(\.isActive)
        let items = activeExpenses.map { recurringTransaction(from: $0, now: now) }
        let recurringIDs = Set(
            transactions
                .filter { transaction in
                    activeExpenses.contains { expense in
                        matches(transaction: transaction, recurringExpense: expense)
                    }
                }
                .map(\.id)
        )

        return RecurringSummary(
            items: items.sorted { lhs, rhs in
                if lhs.expectedDay == rhs.expectedDay {
                    return lhs.monthlyAmount > rhs.monthlyAmount
                }
                return lhs.expectedDay < rhs.expectedDay
            },
            recurringTransactionIDs: recurringIDs
        )
    }

    static func normalizedMerchantName(_ merchantName: String) -> String {
        merchantName
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func recurringTransaction(from record: RecurringExpenseRecord, now: Date) -> RecurringTransaction {
        RecurringTransaction(
            id: record.id,
            merchantName: record.merchantName,
            normalizedMerchantName: Self.normalizedMerchantName(record.merchantName),
            category: record.category,
            monthlyAmount: record.amount,
            expectedDay: record.expectedDay,
            expectedDate: expectedDate(for: record.expectedDay, now: now),
            status: status(for: record.expectedDay, now: now),
            isActive: record.isActive,
            note: record.note
        )
    }

    private func matches(transaction: TransactionRecord, recurringExpense: RecurringExpenseRecord) -> Bool {
        let transactionMerchant = Self.normalizedMerchantName(transaction.merchantName)
        let recurringMerchant = Self.normalizedMerchantName(recurringExpense.merchantName)
        guard !transactionMerchant.isEmpty, transactionMerchant == recurringMerchant else { return false }
        guard recurringExpense.amount > 0 else { return false }
        return abs(transaction.amount - recurringExpense.amount) / recurringExpense.amount <= amountTolerance
    }

    private func expectedDate(for expectedDay: Int, now: Date) -> Date {
        let components = calendar.dateComponents([.year, .month], from: now)
        let day = min(max(expectedDay, 1), daysInMonth(for: now))
        return calendar.date(from: DateComponents(year: components.year, month: components.month, day: day)) ?? now
    }

    private func status(for expectedDay: Int, now: Date) -> RecurringTransactionStatus {
        let expected = expectedDate(for: expectedDay, now: now)
        let startOfToday = calendar.startOfDay(for: now)
        let graceEnd = calendar.date(byAdding: .day, value: gracePeriodDays, to: expected) ?? expected

        if startOfToday < expected {
            return .upcoming
        } else if startOfToday <= graceEnd {
            return .due
        } else {
            return .missed
        }
    }

    private func daysInMonth(for date: Date) -> Int {
        calendar.range(of: .day, in: .month, for: date)?.count ?? 28
    }
}
