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
        guard let amount = draft.amount else {
            throw ValidationError.invalidAmount
        }

        let record = TransactionRecord(
            amount: amount,
            merchantName: draft.merchantName.trimmingCharacters(in: .whitespacesAndNewlines),
            category: draft.category,
            date: draft.date,
            note: draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.insert(record)
        try modelContext.save()
    }

    func updateTransaction(_ record: TransactionRecord, from draft: TransactionDraft) throws {
        guard let amount = draft.amount else {
            throw ValidationError.invalidAmount
        }

        record.amount = amount
        record.merchantName = draft.merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        record.category = draft.category
        record.date = draft.date
        record.note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        record.updatedAt = .now
        try modelContext.save()
    }

    func deleteTransaction(_ record: TransactionRecord) throws {
        modelContext.delete(record)
        try modelContext.save()
    }

    func seedIfNeeded() throws {
        guard try fetchAllTransactions().isEmpty else { return }

        for sample in SampleData.transactions {
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
}
