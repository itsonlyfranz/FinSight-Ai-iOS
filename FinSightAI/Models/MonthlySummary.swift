import Foundation

struct CategorySpend: Identifiable, Equatable, Sendable {
    let id = UUID()
    let category: SpendingCategory
    let amount: Double
    let percentage: Double
}

/// Immutable copy of a transaction, safe to hand to background work (unlike the live SwiftData model).
struct TransactionSnapshot: Identifiable, Equatable, Sendable {
    let id: UUID
    let amount: Decimal
    let merchantName: String
    let category: SpendingCategory
    let date: Date
    let note: String

    init(_ record: TransactionRecord) {
        id = record.id
        amount = record.amount
        merchantName = record.merchantName
        category = record.category
        date = record.date
        note = record.note
    }
}

struct MonthlySummary: Equatable, Sendable {
    let monthStart: Date
    let monthLabel: String
    let totalSpent: Double
    let recurringMonthlySpend: Double
    let recurringTransactionCount: Int
    let oneOffSpent: Double
    let largestRecurringMerchant: String?
    let transactionCount: Int
    let categoryBreakdown: [CategorySpend]
    let recentTransactions: [TransactionSnapshot]
    let averageTransactionValue: Double
    let topCategory: SpendingCategory?
    let topCategoryShare: Double
    let spendingTrendDescription: String
}
