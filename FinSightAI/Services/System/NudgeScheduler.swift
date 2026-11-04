import Foundation
import UserNotifications
import WidgetKit

@MainActor
enum NudgeScheduler {
    private static let deliveredKey = "finsight.sentNudges"
    private static var refreshTask: Task<Void, Error>?

    static func refresh(snapshot: SystemSnapshot) async throws {
        let previous = refreshTask
        let task = Task {
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await apply(snapshot: snapshot)
        }
        refreshTask = task
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func apply(snapshot: SystemSnapshot) async throws {
        WidgetCenter.shared.reloadAllTimelines()
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let pending = await center.pendingNotificationRequests()
        let now = snapshot.date.timeIntervalSince1970
        let saved = UserDefaults.standard.dictionary(forKey: deliveredKey) as? [String: Double] ?? [:]
        var sent = saved.filter { now - $0.value < 40 * 86400 }
        // Keep consumed IDs even after the user clears Notification Center. Future cancelled requests remain eligible.
        let scheduled = UserDefaults.standard.dictionary(forKey: "finsight.scheduledNudges") as? [String: Double] ?? [:]
        for (id, fireDate) in scheduled where fireDate <= now { sent[id] = fireDate }
        let delivered = await center.deliveredNotifications()
        for item in delivered { sent[item.request.identifier] = item.date.timeIntervalSince1970 }
        try Task.checkCancellation()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("finsight.") }.map(\.identifier))
        var nextScheduled: [String: Double] = [:]
        defer {
            UserDefaults.standard.set(nextScheduled, forKey: "finsight.scheduledNudges")
            UserDefaults.standard.set(sent, forKey: deliveredKey)
        }
        for nudge in NudgePlanner.plan(snapshot: snapshot) {
            let id = "finsight." + nudge.id
            guard sent[id] == nil else { continue }
            let content = UNMutableNotificationContent()
            content.title = nudge.title
            content.body = nudge.body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, nudge.date.timeIntervalSince(snapshot.date)), repeats: false)
            try Task.checkCancellation()
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            nextScheduled[id] = nudge.date.timeIntervalSince1970
        }
    }
}
