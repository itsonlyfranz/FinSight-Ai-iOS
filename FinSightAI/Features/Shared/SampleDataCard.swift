import SwiftUI

/// Shown while the ledger is empty. Sample data is strictly opt-in.
struct SampleDataCard: View {
    @Environment(AppContext.self) private var appContext
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("Welcome to FinSight AI", systemImage: "hand.wave.fill")
                .font(AppTheme.Typography.headline)
            Text("Your ledger is empty. Add your first expense from the Transactions tab, or explore the app with example data.")
                .foregroundStyle(AppTheme.mutedInk)
            Button {
                do {
                    try appContext.loadSampleData()
                } catch {
                    errorMessage = error.localizedDescription
                }
            } label: {
                Label("Load sample data", systemImage: "tray.and.arrow.down.fill")
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.primary)
        }
        .finSightCard()
        .alert("Unable to load sample data", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
