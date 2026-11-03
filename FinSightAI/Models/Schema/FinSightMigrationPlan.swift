import Foundation
import Synchronization
import SwiftData

/// Ordered history of schema versions and how to move between them.
enum FinSightMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [FinSightSchemaV1.self, FinSightSchemaV2.self, FinSightSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    // MARK: V2 → V3

    /// V3 only adds the insight-state table, which SwiftData can create without any data work.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: FinSightSchemaV2.self,
        toVersion: FinSightSchemaV3.self
    )

    // MARK: V1 → V2

    /// V1 stored money as `Double` in `amount`; V2 stores exact fixed-point integers in
    /// `amountScaled`. SwiftData's lightweight migration cannot convert between those, so the
    /// legacy amounts are captured before the structural migration and written back afterwards.
    /// Everything else (new models, dropped `.unique`, new `kind` column) is structural.
    static let migrateV1toV2 = MigrationStage.custom(
        fromVersion: FinSightSchemaV1.self,
        toVersion: FinSightSchemaV2.self,
        willMigrate: { context in
            let transactions = try context.fetch(FetchDescriptor<FinSightSchemaV1.TransactionRecord>())
            let recurring = try context.fetch(FetchDescriptor<FinSightSchemaV1.RecurringExpenseRecord>())
            legacyAmounts.withLock { captured in
                captured.transactions = Dictionary(
                    transactions.map { ($0.id, $0.amount) },
                    uniquingKeysWith: { first, _ in first }
                )
                captured.recurring = Dictionary(
                    recurring.map { ($0.id, $0.amount) },
                    uniquingKeysWith: { first, _ in first }
                )
            }
        },
        didMigrate: { context in
            let captured = legacyAmounts.withLock { value in
                defer { value = LegacyAmounts() }
                return value
            }
            for record in try context.fetch(FetchDescriptor<FinSightSchemaV2.TransactionRecord>()) {
                record.amountScaled = Money.scaled(fromLegacy: captured.transactions[record.id] ?? 0)
                record.kind = .expense
            }
            for record in try context.fetch(FetchDescriptor<FinSightSchemaV2.RecurringExpenseRecord>()) {
                record.amountScaled = Money.scaled(fromLegacy: captured.recurring[record.id] ?? 0)
            }
            try context.save()
        }
    )

    private struct LegacyAmounts: Sendable {
        var transactions: [UUID: Double] = [:]
        var recurring: [UUID: Double] = [:]
    }

    private static let legacyAmounts = Mutex(LegacyAmounts())
}
