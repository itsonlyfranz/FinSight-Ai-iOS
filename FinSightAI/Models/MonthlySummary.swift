import Foundation

struct CategorySpend: Identifiable, Equatable {
    let id = UUID()
    let category: SpendingCategory
    let amount: Double
    let percentage: Double
}

struct MonthlySummary: Equatable {
    let monthStart: Date
    let monthLabel: String
    let totalSpent: Double
    let transactionCount: Int
    let categoryBreakdown: [CategorySpend]
    let recentTransactions: [TransactionRecord]
    let averageTransactionValue: Double
    let topCategory: SpendingCategory?
    let topCategoryShare: Double
    let spendingTrendDescription: String
}
