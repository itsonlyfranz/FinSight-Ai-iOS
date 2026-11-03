import Foundation
import SwiftData

enum RecurringTransactionStatus: String, Equatable {
    case upcoming
    case missed
    case due

    var title: String {
        switch self {
        case .upcoming: "Upcoming"
        case .missed: "Missed"
        case .due: "Due"
        }
    }

    var systemImage: String {
        switch self {
        case .upcoming: "calendar.badge.clock"
        case .missed: "exclamationmark.triangle.fill"
        case .due: "calendar.badge.exclamationmark"
        }
    }
}

struct RecurringExpenseDraft: Equatable {
    var merchantName = ""
    var amountText = ""
    var category: SpendingCategory = .bills
    var expectedDay = Calendar.current.component(.day, from: Date())
    var isActive = true
    var note = ""
    var locale: Locale = .current

    init() {}

    init(record: RecurringExpenseRecord) {
        merchantName = record.merchantName
        amountText = CurrencyFormatter.plainNumberString(from: record.amount, locale: locale)
        category = record.category
        expectedDay = record.expectedDay
        isActive = record.isActive
        note = record.note
    }

    init(transaction: TransactionRecord, calendar: Calendar = .current) {
        merchantName = transaction.merchantName
        amountText = CurrencyFormatter.plainNumberString(from: transaction.amount, locale: locale)
        category = transaction.category
        expectedDay = calendar.component(.day, from: transaction.date)
        note = transaction.note
    }

    var amount: Decimal? {
        AmountParser.parse(amountText, locale: locale)
    }

    var validationError: String? {
        guard !merchantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Merchant is required."
        }
        guard let amount else { return "Enter a valid amount." }
        guard amount > 0 else { return "Amount must be greater than zero." }
        guard (1...31).contains(expectedDay) else { return "Expected day must be between 1 and 31." }
        return nil
    }
}

struct RecurringTransaction: Identifiable, Equatable {
    let id: UUID
    let merchantName: String
    let normalizedMerchantName: String
    let category: SpendingCategory
    let monthlyAmount: Double
    let expectedDay: Int
    let expectedDate: Date
    let status: RecurringTransactionStatus
    let isActive: Bool
    let note: String
}

struct RecurringSummary: Equatable {
    static let empty = RecurringSummary(items: [], recurringTransactionIDs: [])

    /// Active recurring definitions.
    let items: [RecurringTransaction]
    /// Paused definitions. Kept so they stay reachable to re-activate or delete.
    let inactiveItems: [RecurringTransaction]
    let recurringTransactionIDs: Set<UUID>

    init(
        items: [RecurringTransaction],
        inactiveItems: [RecurringTransaction] = [],
        recurringTransactionIDs: Set<UUID>
    ) {
        self.items = items
        self.inactiveItems = inactiveItems
        self.recurringTransactionIDs = recurringTransactionIDs
    }

    /// Active recurring charges that count as spending (savings transfers are excluded).
    var spendingItems: [RecurringTransaction] {
        items.filter { $0.category.countsAsSpending }
    }

    var totalMonthlySpend: Double {
        spendingItems.reduce(0) { $0 + $1.monthlyAmount }
    }

    var itemCount: Int {
        spendingItems.count
    }

    var hasAnyItems: Bool {
        !items.isEmpty || !inactiveItems.isEmpty
    }

    var largestItem: RecurringTransaction? {
        spendingItems.max { $0.monthlyAmount < $1.monthlyAmount }
    }
}
