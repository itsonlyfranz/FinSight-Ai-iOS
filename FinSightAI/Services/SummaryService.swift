import Foundation

protocol SummaryService {
    func makeMonthlySummary(
        from transactions: [TransactionRecord],
        recurringSummary: RecurringSummary,
        now: Date
    ) -> MonthlySummary
    func monthlySections(from transactions: [TransactionRecord]) -> [TransactionMonthSection]
}

struct TransactionMonthSection: Identifiable, Equatable {
    let id: String
    let title: String
    let transactions: [TransactionRecord]
}
