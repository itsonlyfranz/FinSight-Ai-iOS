import Foundation
import SwiftData

/// Loads the engine's history from SwiftData one calendar month at a time, with a predicate bounded
/// to that month, instead of fetching every transaction ever logged.
enum InsightDataLoader {
    /// Months of history the engine looks at (the current month plus the 11 before it). Enough for
    /// 6-month baselines and quarterly subscriptions to repeat three times.
    static let historyMonths = 12

    static func entries(
        in context: ModelContext,
        now: Date,
        calendar: Calendar,
        months: Int = historyMonths
    ) throws -> [LedgerEntry] {
        var result: [LedgerEntry] = []
        for offset in 0..<max(1, months) {
            guard let shifted = calendar.date(byAdding: .month, value: -offset, to: now),
                  let interval = calendar.dateInterval(of: .month, for: shifted) else { continue }
            result.append(contentsOf: try entries(in: context, interval: interval))
        }
        return result
    }

    /// Transactions with `interval.start <= date < interval.end`.
    static func entries(in context: ModelContext, interval: DateInterval) throws -> [LedgerEntry] {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<TransactionRecord>(
            predicate: #Predicate { $0.date >= start && $0.date < end },
            sortBy: [SortDescriptor(\.date)]
        )
        return try context.fetch(descriptor).map(LedgerEntry.init)
    }

    static func suppressions(in context: ModelContext) throws -> [InsightSuppression] {
        try context.fetch(FetchDescriptor<InsightStateRecord>()).compactMap { record in
            guard let status = InsightSuppression.Status(rawValue: record.statusRawValue) else { return nil }
            return InsightSuppression(insightID: record.insightID, status: status, until: record.snoozedUntil)
        }
    }
}
