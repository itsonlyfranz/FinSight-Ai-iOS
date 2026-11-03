import OSLog
import SwiftData
import SwiftUI

@main
struct FinSightAIApp: App {
    private static let logger = Logger(subsystem: "com.finsightai.app", category: "Launch")

    @State private var launchState: LaunchState

    init() {
        _launchState = State(initialValue: Self.makeLaunchState())
    }

    var body: some Scene {
        WindowGroup {
            switch launchState {
            case .ready(let environment):
                RootTabView()
                    .environment(environment.appContext)
                    .modelContainer(environment.modelContainer)
                    .task {
                        do {
                            try environment.appContext.bootstrap()
                        } catch {
                            Self.logger.error("Bootstrap failed: \(error.localizedDescription, privacy: .public)")
                            launchState = .failed(error.localizedDescription)
                        }
                    }
            case .failed(let message):
                StoreRecoveryView(
                    message: message,
                    onRetry: { launchState = Self.makeLaunchState() },
                    onStartFresh: { startFresh() }
                )
            }
        }
    }

    private static func makeLaunchState() -> LaunchState {
        do {
            return .ready(try AppEnvironment.make())
        } catch {
            logger.error("Unable to open the data store: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// Moves the unreadable store aside (kept on disk, not deleted) and opens a new, empty one.
    private func startFresh() {
        do {
            let backup = try StoreBackup.moveStoreAside(storeURL: ModelConfiguration().url)
            Self.logger.notice("Moved unreadable store to \(backup.path, privacy: .public)")
            launchState = Self.makeLaunchState()
        } catch {
            Self.logger.error("Could not move the store aside: \(error.localizedDescription, privacy: .public)")
            launchState = .failed("Your data couldn't be backed up, so nothing was changed. \(error.localizedDescription)")
        }
    }
}

private enum LaunchState {
    case ready(AppEnvironment)
    case failed(String)
}

private struct StoreRecoveryView: View {
    let message: String
    let onRetry: () -> Void
    let onStartFresh: () -> Void
    @State private var confirmingStartFresh = false

    var body: some View {
        VStack(spacing: AppTheme.Spacing.lg) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(.system(size: 56))
                .foregroundStyle(AppTheme.primary)
                .accessibilityHidden(true)
            Text("FinSight AI can't open your data")
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Nothing has been deleted. You can try again, or start with an empty ledger — your existing data is moved to a backup folder on this device, not erased.")
                .foregroundStyle(AppTheme.mutedInk)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedInk)
                .multilineTextAlignment(.center)

            Button("Try Again", action: onRetry)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
            Button("Start Fresh (keep a backup)", role: .destructive) {
                confirmingStartFresh = true
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.backgroundGradient.ignoresSafeArea())
        .confirmationDialog(
            "Start with an empty ledger?",
            isPresented: $confirmingStartFresh,
            titleVisibility: .visible
        ) {
            Button("Move data to backup and start fresh", role: .destructive, action: onStartFresh)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your current data is moved to a backup folder, not deleted.")
        }
    }
}
