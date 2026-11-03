import Foundation
import SwiftData

enum AppStoreSchema {
    /// The current (latest) schema.
    static var schema: Schema {
        Schema(versionedSchema: FinSightSchemaV2.self)
    }

    /// Opens (and, when needed, migrates) the store at `configuration`.
    static func makeContainer(configuration: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: FinSightMigrationPlan.self,
            configurations: configuration
        )
    }
}

/// Moves a SwiftData store that can't be opened out of the way (never deleting it), so the
/// user can start fresh without losing the original data.
enum StoreBackup {
    private static let storeSuffixes = ["", "-wal", "-shm"]

    /// Moves the store files into a timestamped folder next to the store and returns that folder.
    @discardableResult
    static func moveStoreAside(
        storeURL: URL,
        fileManager: FileManager = .default,
        now: Date = .now
    ) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
        let backupDirectory = storeURL
            .deletingLastPathComponent()
            .appendingPathComponent("StoreBackup-\(stamp)", isDirectory: true)
        try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

        for suffix in storeSuffixes {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = backupDirectory.appendingPathComponent(source.lastPathComponent)
            try fileManager.moveItem(at: source, to: destination)
        }
        return backupDirectory
    }
}
