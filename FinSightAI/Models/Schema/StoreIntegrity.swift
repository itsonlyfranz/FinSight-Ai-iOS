import Foundation
import SwiftData

/// App-level uniqueness. CloudKit-compatible schemas cannot declare `.unique`, so duplicates
/// (which could also arrive from sync later) are collapsed here instead, keeping the most
/// recently updated row.
enum StoreIntegrity {
    /// Removes duplicate rows and returns how many were deleted.
    @discardableResult
    static func dedupe(in context: ModelContext) throws -> Int {
        var removed = 0
        removed += try dedupe(context, key: { (record: TransactionRecord) in record.id }, updatedAt: \.updatedAt)
        removed += try dedupe(context, key: { (record: RecurringExpenseRecord) in record.id }, updatedAt: \.updatedAt)
        removed += try dedupe(
            context,
            key: { (record: AIResponseCacheRecord) in "\(record.featureRawValue)|\(record.cacheKey)" },
            updatedAt: \.updatedAt
        )
        removed += try dedupe(context, key: { (record: IncomeSource) in record.id }, updatedAt: \.updatedAt)
        removed += try dedupe(context, key: { (record: Budget) in record.categoryRawValue }, updatedAt: \.updatedAt)
        removed += try dedupe(context, key: { (record: SavingsGoal) in record.id }, updatedAt: \.updatedAt)
        removed += try dedupe(context, key: { (record: GoalContribution) in record.id }, updatedAt: \.date)
        removed += try dedupe(context, key: { (record: InsightStateRecord) in record.insightID }, updatedAt: \.updatedAt)
        // Single-row model: every settings row shares one key.
        removed += try dedupe(context, key: { (_: AppSettings) in 0 }, updatedAt: \.updatedAt)
        if removed > 0 { try context.save() }
        return removed
    }

    private static func dedupe<Model: PersistentModel, Key: Hashable>(
        _ context: ModelContext,
        key: (Model) -> Key,
        updatedAt: KeyPath<Model, Date>
    ) throws -> Int {
        let all = try context.fetch(FetchDescriptor<Model>())
        let groups = Dictionary(grouping: all, by: key)
        var removed = 0
        for (_, rows) in groups where rows.count > 1 {
            let keeper = rows.max { $0[keyPath: updatedAt] < $1[keyPath: updatedAt] }
            for row in rows where row.persistentModelID != keeper?.persistentModelID {
                context.delete(row)
                removed += 1
            }
        }
        return removed
    }
}

extension AppSettings {
    /// The single settings row, created from the device's region on first use.
    @MainActor
    static func fetchOrCreate(in context: ModelContext, locale: Locale = .current, calendar: Calendar = .current) throws -> AppSettings {
        if let existing = try context.fetch(FetchDescriptor<AppSettings>(sortBy: [SortDescriptor(\.createdAt)])).first {
            return existing
        }
        let settings = AppSettings.makeDefault(locale: locale, calendar: calendar)
        context.insert(settings)
        try context.save()
        return settings
    }
}
