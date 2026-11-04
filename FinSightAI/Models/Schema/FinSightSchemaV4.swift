import Foundation
import SwiftData

/// Schema V4 — adds saved what-if scenarios.
///
/// Every V3 model is unchanged and reused as-is, so V3 → V4 is a lightweight migration that only
/// adds the `SavedScenarioRecord` table. CloudKit-compatible like V2 and V3: defaults everywhere,
/// no `.unique` (name uniqueness is enforced by the app when saving, and duplicate ids by
/// `StoreIntegrity`).
enum FinSightSchemaV4: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(4, 0, 0) }

    static var models: [any PersistentModel.Type] {
        FinSightSchemaV3.models + [SavedScenarioRecord.self]
    }

    /// A named set of simulator inputs. Only the inputs are stored, as JSON, so the scenario is
    /// re-run against the current baseline every time and new input fields never need a migration.
    @Model
    final class SavedScenarioRecord {
        var id: UUID = UUID()
        var name: String = ""
        var scenarioData: Data = Data()
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        init(
            id: UUID = UUID(),
            name: String,
            scenario: SimulationScenario,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.name = name
            self.scenarioData = Self.encode(scenario)
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// The stored inputs; nil if the data can't be read, so one bad row never breaks the list.
        var scenario: SimulationScenario? {
            get { try? JSONDecoder().decode(SimulationScenario.self, from: scenarioData) }
            set { scenarioData = newValue.map(Self.encode) ?? Data() }
        }

        private static func encode(_ scenario: SimulationScenario) -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return (try? encoder.encode(scenario)) ?? Data()
        }
    }
}
