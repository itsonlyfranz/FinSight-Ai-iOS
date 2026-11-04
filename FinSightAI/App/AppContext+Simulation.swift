import Foundation
import SwiftData

/// The forward simulator's state: the scenario being edited, its results and the saved scenarios.
extension AppContext {
    /// Categories seeded with a starting cut, so the first screen already shows something to adjust.
    static let seededCutCount = 3
    static let seededCutPercent = 10
    /// Most scenarios compared at once (the one being edited plus saved ones).
    static let maximumComparedScenarios = 4
    /// Identity of the scenario being edited inside a comparison, stable across refreshes.
    static let currentScenarioID = UUID(uuidString: "00000000-0000-0000-0000-00000000C0DE")!

    // MARK: - Running

    /// Unfinished goals with the pace each already receives (Phase 2's pace), for the countdown.
    func simulationGoals(now: Date = .now) -> [SimulationGoal] {
        savingsGoals.filter { !$0.isReached }.map { goal in
            SimulationGoal(
                id: goal.id,
                name: goal.name,
                targetAmount: goal.targetAmount,
                savedAmount: goal.savedAmount,
                targetDate: goal.targetDate,
                monthlyPace: goalProjection(for: goal, now: now).monthlyPace
            )
        }
    }

    func simulate(_ scenario: SimulationScenario, now: Date = .now) -> SimulationResult {
        simulationService.simulate(
            baseline: runRateBaseline,
            scenario: scenario,
            goals: simulationGoals(now: now),
            now: now,
            calendar: settings?.calendar() ?? .current
        )
    }

    func narrationContext(for scenario: SimulationScenario, result: SimulationResult) -> SimulationNarrationContext {
        SimulationFacts.context(scenario: scenario, baseline: runRateBaseline, result: result)
    }

    // MARK: - Seeding

    /// Starts the working scenario with a modest cut in the user's largest everyday categories. Does
    /// nothing until there is spending to seed from. It keeps following the data (as transactions are
    /// added one by one) only while the scenario is still exactly what it seeded, so it never
    /// overwrites anything the user changed or loaded.
    func seedScenarioIfNeeded() {
        let lines = runRateBaseline.cuttableLines
        guard !lines.isEmpty else { return }
        guard !isScenarioSeeded || workingScenario == autoSeededScenario else { return }
        var scenario = SimulationScenario()
        for line in lines.prefix(Self.seededCutCount) {
            scenario.setCut(Self.seededCutPercent, for: line.category)
        }
        workingScenario = scenario
        autoSeededScenario = scenario
        isScenarioSeeded = true
    }

    /// Back to the seeded starting point.
    func resetWorkingScenario() {
        workingScenario = SimulationScenario()
        isScenarioSeeded = false
        seedScenarioIfNeeded()
    }

    // MARK: - Saved scenarios

    func reloadScenarios() throws {
        savedScenarios = try modelContext.fetch(FetchDescriptor<SavedScenarioRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
    }

    /// Saves the working scenario under `name`. A name already in use (ignoring case) is updated
    /// rather than duplicated.
    @discardableResult
    func saveWorkingScenario(named name: String, now: Date = .now) throws -> SavedScenarioRecord {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlanningError.missingName }
        let scenario = workingScenario.normalized
        let record: SavedScenarioRecord
        if let existing = savedScenarios.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            existing.name = name
            existing.scenario = scenario
            existing.updatedAt = now
            record = existing
        } else {
            record = SavedScenarioRecord(name: name, scenario: scenario, createdAt: now, updatedAt: now)
            modelContext.insert(record)
        }
        try modelContext.save()
        try reloadScenarios()
        return record
    }

    /// Makes a saved scenario the one being edited. Returns false if its data can't be read.
    @discardableResult
    func loadScenario(_ record: SavedScenarioRecord) -> Bool {
        guard let scenario = record.scenario else { return false }
        workingScenario = scenario
        isScenarioSeeded = true
        return true
    }

    func deleteScenario(_ record: SavedScenarioRecord) throws {
        modelContext.delete(record)
        try modelContext.save()
        try reloadScenarios()
    }

    /// The working scenario followed by the chosen saved ones, each run against today's baseline.
    func scenarioComparison(including savedIDs: [UUID], now: Date = .now) -> ScenarioComparison {
        let current = ScenarioComparison.Entry(id: Self.currentScenarioID, name: "Current", result: simulate(workingScenario, now: now))
        let saved = savedIDs.prefix(Self.maximumComparedScenarios - 1).compactMap { id -> ScenarioComparison.Entry? in
            guard let record = savedScenarios.first(where: { $0.id == id }), let scenario = record.scenario else { return nil }
            return ScenarioComparison.Entry(id: record.id, name: record.name, result: simulate(scenario, now: now))
        }
        return ScenarioComparison.make([current] + saved)
    }
}
