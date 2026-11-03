import Foundation
import SwiftData

@MainActor
final class SwiftDataTransactionRepository: TransactionRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func fetchAllTransactions() throws -> [TransactionRecord] {
        let descriptor = FetchDescriptor<TransactionRecord>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func addTransaction(from draft: TransactionDraft) throws {
        let amount = try ValidationError.validatedAmount(draft.amount)

        let record = TransactionRecord(
            amount: amount,
            kind: draft.kind,
            merchantName: draft.merchantName.trimmingCharacters(in: .whitespacesAndNewlines),
            category: draft.kind == .income ? .other : draft.category,
            date: draft.date,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.insert(record)
        try modelContext.save()
    }

    func updateTransaction(_ record: TransactionRecord, from draft: TransactionDraft) throws {
        let amount = try ValidationError.validatedAmount(draft.amount)

        record.amount = amount
        record.kind = draft.kind
        record.merchantName = draft.merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        record.category = draft.kind == .income ? .other : draft.category
        record.date = draft.date
        record.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        record.updatedAt = .now
        try modelContext.save()
    }

    func deleteTransaction(_ record: TransactionRecord) throws {
        modelContext.delete(record)
        try modelContext.save()
    }

    /// Inserts demo transactions. Only ever called from an explicit user action, and
    /// only into an empty ledger so it can never duplicate or overwrite real data.
    func loadSampleData(now: Date = .now) throws {
        guard try fetchAllTransactions().isEmpty else { return }

        for sample in SampleData.makeTransactions(now: now) {
            modelContext.insert(sample)
        }
        try modelContext.save()
    }
}

enum ValidationError: LocalizedError {
    case invalidAmount

    var errorDescription: String? {
        switch self {
        case .invalidAmount: "Enter a valid amount greater than zero."
        }
    }

    /// Repository-level guard: the amount must be a finite number greater than zero, within the storable range.
    static func validatedAmount(_ amount: Decimal?) throws -> Decimal {
        guard let amount, !amount.isNaN, amount > 0, amount <= Money.maximumMagnitude else {
            throw ValidationError.invalidAmount
        }
        return amount
    }
}
