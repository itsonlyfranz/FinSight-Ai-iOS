import Foundation
import SwiftData

/// Schema V3 — adds persisted insight state (dismissed and snoozed insights).
///
/// Every V2 model is unchanged and is reused as-is, so V2 → V3 is a lightweight migration that
/// only adds the `InsightStateRecord` table. CloudKit-compatible like V2: defaults everywhere, no
/// `.unique` (uniqueness per `insightID` is enforced by `StoreIntegrity`).
enum FinSightSchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }

    static var models: [any PersistentModel.Type] {
        FinSightSchemaV2.models + [InsightStateRecord.self]
    }

    /// The user's decision about one insight. `insightID` is the engine's period-scoped id.
    @Model
    final class InsightStateRecord {
        var id: UUID = UUID()
        var insightID: String = ""
        var statusRawValue: String = InsightSuppression.Status.dismissed.rawValue
        /// End of the snooze; `nil` for dismissals.
        var snoozedUntil: Date?
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        init(
            id: UUID = UUID(),
            insightID: String,
            status: InsightSuppression.Status,
            snoozedUntil: Date? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.insightID = insightID
            self.statusRawValue = status.rawValue
            self.snoozedUntil = snoozedUntil
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var status: InsightSuppression.Status {
            get { InsightSuppression.Status(rawValue: statusRawValue) ?? .dismissed }
            set { statusRawValue = newValue.rawValue }
        }
    }
}
