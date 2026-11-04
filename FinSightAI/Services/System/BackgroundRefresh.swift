import BackgroundTasks
import Foundation
import OSLog

@MainActor
enum BackgroundRefresh {
    static let identifier = "com.finsightai.refresh"
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = SystemSnapshot.nextRefresh(after: .now)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { Logger(subsystem: "com.finsightai.app", category: "Background").info("Refresh scheduling unavailable: \(error.localizedDescription)") }
    }
    static func run() async {
        defer { schedule() }
        do {
            try Task.checkCancellation()
            let snapshot = try SystemSnapshot.load()
            try Task.checkCancellation()
            try await NudgeScheduler.refresh(snapshot: snapshot)
        } catch {
            Logger(subsystem: "com.finsightai.app", category: "Background").error("Refresh failed: \(error.localizedDescription)")
        }
    }
}
