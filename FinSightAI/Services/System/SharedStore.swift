import Foundation
import SwiftData

/// The app migrates its existing store before any extension is allowed to open it.
enum SharedStore {
    static let groupID = "group.com.finsightai.app"
    static var groupURL: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
    static var storeURL: URL { groupURL?.appendingPathComponent("Ledger/default.store") ?? ModelConfiguration().url }
    static var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

    static func configuration() throws -> ModelConfiguration {
        guard let groupURL else {
            guard !isExtension else { throw SharedStoreError.openApp }
            return ModelConfiguration(cloudKitDatabase: .none)
        }
        let url = try prepare(groupURL: groupURL, legacyURL: ModelConfiguration().url, allowMigration: !isExtension)
        return ModelConfiguration(url: url, cloudKitDatabase: .none)
    }

    static func prepare(groupURL: URL, legacyURL: URL, allowMigration: Bool) throws -> URL {
        let directory = groupURL.appendingPathComponent("Ledger", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            guard allowMigration else { throw SharedStoreError.openApp }
            let staging = groupURL.appendingPathComponent("Ledger-staging", isDirectory: true)
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let legacy = legacyURL
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: legacy.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: staging.appendingPathComponent("default.store" + suffix))
                }
            }
            try FileManager.default.moveItem(at: staging, to: directory)
        }
        return directory.appendingPathComponent("default.store")
    }
    static func open() throws -> ModelContainer { try AppStoreSchema.makeContainer(configuration: configuration()) }
}

enum SharedStoreError: LocalizedError {
    case openApp
    var errorDescription: String? { "Open FinSight AI to prepare the shared ledger. App Group signing is required for extensions." }
}
