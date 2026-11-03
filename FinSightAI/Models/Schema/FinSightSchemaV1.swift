import Foundation
import SwiftData

/// Frozen snapshot of the schema that shipped before versioning (Phases 0 and earlier).
///
/// Do not edit these definitions: SwiftData identifies the on-disk version by hashing them, so any
/// change would make existing stores unrecognisable. They exist only so the migration plan can read
/// a V1 store and move it to V2. Application code uses the V2 types (see `CurrentSchema.swift`).
enum FinSightSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [TransactionRecord.self, RecurringExpenseRecord.self, AIResponseCacheRecord.self]
    }

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
    }

    @Model
    final class AIResponseCacheRecord {
        @Attribute(.unique) var cacheKey: String
        var featureRawValue: String
        var sourceFingerprint: String
        var payload: String
        var generatedAt: Date
        var lastAutoRefreshDayKey: String?
        var providerIdentifier: String
        var failureMessage: String?
        var updatedAt: Date

        init(
            cacheKey: String,
            feature: AICacheFeature,
            sourceFingerprint: String,
            payload: String,
            generatedAt: Date,
            lastAutoRefreshDayKey: String? = nil,
            providerIdentifier: String,
            failureMessage: String? = nil,
            updatedAt: Date = .now
        ) {
            self.cacheKey = cacheKey
            self.featureRawValue = feature.rawValue
            self.sourceFingerprint = sourceFingerprint
            self.payload = payload
            self.generatedAt = generatedAt
            self.lastAutoRefreshDayKey = lastAutoRefreshDayKey
            self.providerIdentifier = providerIdentifier
            self.failureMessage = failureMessage
            self.updatedAt = updatedAt
        }
    }
}
