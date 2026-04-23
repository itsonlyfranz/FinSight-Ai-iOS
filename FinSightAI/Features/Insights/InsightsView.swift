import SwiftUI

struct InsightsView: View {
    @Environment(AppContext.self) private var appContext

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryHeader

                    switch appContext.insightState {
                    case .idle, .loading:
                        ProgressView("Analyzing spending summary...")
                            .frame(maxWidth: .infinity, minHeight: 180)
                    case .available(let cards):
                        ForEach(cards) { card in
                            InsightPanel(card: card)
                        }
                    case .unavailable(let message), .failure(let message):
                        unsupportedPanel(message: message)
                    }
                }
                .padding(20)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("AI Insights")
        }
        .task(id: appContext.monthlySummary.monthLabel) {
            await appContext.loadInsights()
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This month")
                .font(.headline)
            Text("\(CurrencyFormatter.pesoString(from: appContext.monthlySummary.totalSpent)) across \(appContext.monthlySummary.transactionCount) entries")
                .font(.title3.weight(.semibold))
            Text("Insights are generated from processed monthly summaries rather than raw logs.")
                .font(.footnote)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func unsupportedPanel(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("AI unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text(message)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

private struct InsightPanel: View {
    let card: InsightCard

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(card.kind.title, systemImage: card.kind.systemImage)
                .font(.headline)
                .foregroundStyle(AppTheme.ink)

            Text(card.body)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}
