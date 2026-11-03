import Foundation
import SwiftData

/// The deterministic insight engine, wired to the store.
extension AppContext {
    /// Days a snooze lasts.
    static let insightSnoozeDays = 7

    /// Recomputes insights from the last `LedgerEntry.historyMonths` months of the in-memory
    /// `transactions` (the same ledger the budget figures use) and applies the saved dismissals and snoozes.
    func reloadEngineInsights(now: Date = .now) throws {
        let calendar = settings?.calendar() ?? .current
        let input = InsightInput(
            now: now,
            calendar: calendar,
            entries: LedgerEntry.history(from: transactions, now: now, calendar: calendar),
            budgets: budgetProgress.map { BudgetLimit(category: $0.category, limit: $0.limit) },
            recurringMonthlyIncome: monthlyRecurringIncome,
            reserveBalance: ReserveCalculator.reserve(from: savingsGoals.map { GoalBalance(name: $0.name, saved: $0.savedAmount) })
        )
        allEngineInsights = InsightEngine().insights(for: input)
        try refreshInsightVisibility(now: now)
    }

    func dismissInsight(_ insight: Insight, now: Date = .now) throws {
        try setSuppression(for: insight.id, status: .dismissed, until: nil, now: now)
    }

    func snoozeInsight(_ insight: Insight, days: Int = AppContext.insightSnoozeDays, now: Date = .now) throws {
        let calendar = settings?.calendar() ?? .current
        let until = calendar.date(byAdding: .day, value: days, to: now) ?? now.addingTimeInterval(Double(days) * 86_400)
        try setSuppression(for: insight.id, status: .snoozed, until: until, now: now)
    }

    /// Brings back every dismissed and snoozed insight.
    func restoreHiddenInsights(now: Date = .now) throws {
        for record in try modelContext.fetch(FetchDescriptor<InsightStateRecord>()) {
            modelContext.delete(record)
        }
        try modelContext.save()
        try refreshInsightVisibility(now: now)
    }

    var hiddenInsightCount: Int { allEngineInsights.count - engineInsights.count }

    private func setSuppression(for insightID: String, status: InsightSuppression.Status, until: Date?, now: Date) throws {
        let existing = try modelContext.fetch(FetchDescriptor<InsightStateRecord>(
            predicate: #Predicate { $0.insightID == insightID }
        ))
        if let record = existing.first {
            record.status = status
            record.snoozedUntil = until
            record.updatedAt = now
        } else {
            modelContext.insert(InsightStateRecord(insightID: insightID, status: status, snoozedUntil: until, createdAt: now, updatedAt: now))
        }
        try modelContext.save()
        try refreshInsightVisibility(now: now)
    }

    private func refreshInsightVisibility(now: Date) throws {
        insightSuppressions = try InsightDataLoader.suppressions(in: modelContext)
        engineInsights = InsightVisibility.visible(allEngineInsights, suppressions: insightSuppressions, now: now)
    }
}
