import Foundation

struct TransactionDraft: Equatable {
    var amountText = ""
    var category: SpendingCategory = .groceries
    var date = Date()
    var note = ""

    init() {}

    init(record: TransactionRecord) {
        amountText = CurrencyFormatter.plainNumberString(from: record.amount)
        category = record.category
        date = record.date
        note = record.note
    }

    var amount: Double? {
        Double(amountText.replacingOccurrences(of: ",", with: ""))
    }

    var validationError: String? {
        guard let amount else { return "Enter a valid amount." }
        guard amount > 0 else { return "Amount must be greater than zero." }
        return nil
    }
}
