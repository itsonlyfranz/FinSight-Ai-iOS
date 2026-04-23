import Foundation

@MainActor
protocol TransactionRepository {
    func fetchAllTransactions() throws -> [TransactionRecord]
    func addTransaction(from draft: TransactionDraft) throws
    func updateTransaction(_ record: TransactionRecord, from draft: TransactionDraft) throws
    func deleteTransaction(_ record: TransactionRecord) throws
    func seedIfNeeded() throws
}
