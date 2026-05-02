import Foundation
import SwiftData

@Model
final class TransactionRecord {
    @Attribute(.unique) var id: UUID
    var amount: Double
    var merchantNameStorage: String?
    var categoryRawValue: String
    var date: Date
    var note: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        amount: Double,
        merchantName: String = "",
        category: SpendingCategory,
        date: Date,
        note: String = "",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.amount = amount
        self.merchantNameStorage = merchantName
        self.categoryRawValue = category.rawValue
        self.date = date
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var category: SpendingCategory {
        get { SpendingCategory(rawValue: categoryRawValue) ?? .other }
        set { categoryRawValue = newValue.rawValue }
    }

    var merchantName: String {
        get { merchantNameStorage ?? "" }
        set { merchantNameStorage = newValue }
    }
}
