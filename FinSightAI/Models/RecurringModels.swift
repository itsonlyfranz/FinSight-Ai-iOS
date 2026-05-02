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

@Model
final class RecurringExpenseRecord {
    @Attribute(.unique) var id: UUID
    var merchantNameStorage: String?
    var amount: Double
    var categoryRawValue: String
    var expectedDay: Int
    var isActive: Bool
    var note: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        merchantName: String,
        amount: Double,
        category: SpendingCategory,
        expectedDay: Int,
        isActive: Bool = true,
        note: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.merchantNameStorage = merchantName
        self.amount = amount
        self.categoryRawValue = category.rawValue
        self.expectedDay = min(max(expectedDay, 1), 31)
        self.isActive = isActive
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var merchantName: String {
        get { merchantNameStorage ?? "" }
        set { merchantNameStorage = newValue }
    }

    var category: SpendingCategory {
        get { SpendingCategory(rawValue: categoryRawValue) ?? .other }
        set { categoryRawValue = newValue.rawValue }
    }
}

struct RecurringExpenseDraft: Equatable {
    var merchantName = ""
    var amountText = ""
    var category: SpendingCategory = .bills
    var expectedDay = Calendar.current.component(.day, from: Date())
    var isActive = true
    var note = ""

    init() {}

    init(record: RecurringExpenseRecord) {
        merchantName = record.merchantName
        amountText = CurrencyFormatter.plainNumberString(from: record.amount)
        category = record.category
        expectedDay = record.expectedDay
        isActive = record.isActive
        note = record.note
    }

    init(transaction: TransactionRecord, calendar: Calendar = .current) {
        merchantName = transaction.merchantName
        amountText = CurrencyFormatter.plainNumberString(from: transaction.amount)
        category = transaction.category
        expectedDay = calendar.component(.day, from: transaction.date)
        note = transaction.note
    }

    var amount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: ""))
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

    let items: [RecurringTransaction]
    let recurringTransactionIDs: Set<UUID>

    var totalMonthlySpend: Double {
        items.reduce(0) { $0 + $1.monthlyAmount }
    }

    var itemCount: Int {
        items.count
    }

    var largestItem: RecurringTransaction? {
        items.max { $0.monthlyAmount < $1.monthlyAmount }
    }
}
