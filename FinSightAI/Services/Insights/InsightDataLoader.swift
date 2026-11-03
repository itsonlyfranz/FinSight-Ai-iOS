import Foundation
import SwiftData

/// Loads the saved insight dismissals and snoozes from SwiftData.
enum InsightDataLoader {
    static func suppressions(in context: ModelContext) throws -> [InsightSuppression] {
        try context.fetch(FetchDescriptor<InsightStateRecord>()).compactMap { record in
            guard let status = InsightSuppression.Status(rawValue: record.statusRawValue) else { return nil }
            return InsightSuppression(insightID: record.insightID, status: status, until: record.snoozedUntil)
        }
    }
}
