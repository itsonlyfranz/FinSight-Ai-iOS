import Foundation

/// Side-by-side figures for the scenarios the user picked to compare.
struct ScenarioComparison: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let result: SimulationResult
    }

    struct Row: Identifiable, Equatable, Sendable {
        let entry: Entry
        /// 12-month balance minus the first entry's, so the first entry reads as the reference.
        let twelveMonthDelta: Decimal
        let isBest: Bool

        var id: UUID { entry.id }
    }

    let rows: [Row]

    /// The entry with the largest 12-month balance (the first one wins ties); nil with fewer than two.
    var best: Entry? { rows.first { $0.isBest }?.entry }

    static func make(_ entries: [Entry]) -> ScenarioComparison {
        guard let reference = entries.first else { return ScenarioComparison(rows: []) }
        let top = entries.map { $0.result.twelveMonths }.max() ?? 0
        let winner = entries.count > 1 ? entries.firstIndex { $0.result.twelveMonths == top } : nil
        let rows = entries.enumerated().map { index, entry in
            Row(
                entry: entry,
                twelveMonthDelta: entry.result.twelveMonths - reference.result.twelveMonths,
                isBest: index == winner
            )
        }
        return ScenarioComparison(rows: rows)
    }
}
