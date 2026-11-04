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
        /// The name shown for this row; a repeated name gets a " (2)", " (3)" suffix so rows stay distinct.
        let label: String

        var id: UUID { entry.id }
    }

    let rows: [Row]

    /// The entry with the largest 12-month balance (the first one wins ties); nil with fewer than two.
    var best: Entry? { rows.first { $0.isBest }?.entry }

    /// The display label of `best`.
    var bestLabel: String? { rows.first { $0.isBest }?.label }

    /// The first row's label: the reference the other rows' deltas are measured against.
    var referenceLabel: String? { rows.first?.label }

    static func make(_ entries: [Entry]) -> ScenarioComparison {
        guard let reference = entries.first else { return ScenarioComparison(rows: []) }
        let top = entries.map { $0.result.twelveMonths }.max() ?? 0
        let winner = entries.count > 1 ? entries.firstIndex { $0.result.twelveMonths == top } : nil
        var nameCounts: [String: Int] = [:]
        let rows = entries.enumerated().map { index, entry in
            let count = (nameCounts[entry.name] ?? 0) + 1
            nameCounts[entry.name] = count
            return Row(
                entry: entry,
                twelveMonthDelta: entry.result.twelveMonths - reference.result.twelveMonths,
                isBest: index == winner,
                label: count == 1 ? entry.name : "\(entry.name) (\(count))"
            )
        }
        return ScenarioComparison(rows: rows)
    }
}
