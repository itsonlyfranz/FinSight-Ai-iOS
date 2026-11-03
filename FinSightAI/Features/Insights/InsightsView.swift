import SwiftUI

struct InsightsView: View {
    @Environment(AppContext.self) private var appContext

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    summaryHeader

                    switch appContext.insightState {
                    case .empty:
                        FinSightEmptyState(
                            title: "No insights yet",
                            systemImage: "sparkles",
                            message: "Log a few expenses and FinSight AI will turn them into insights."
                        )
                        .finSightCard()
                    case .idle, .loading:
                        VStack(spacing: AppTheme.Spacing.md) {
                            FinSightInsightSkeleton()
                            FinSightInsightSkeleton()
                            FinSightInsightSkeleton()
                        }
                    case .available(let content):
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            HStack {
                                FinSightStatusLine(text: RelativeTimestampFormatter.updatedString(for: content.lastUpdated))
                                Spacer()
                                FinSightStreamingRefreshControl(
                                    isRefreshing: content.isRefreshing || appContext.isInsightRefreshInFlight,
                                    action: {
                                    Task {
                                        await appContext.loadInsights(forceRefresh: true)
                                    }
                                },
                                    buttonStyleKind: .prominent
                                )
                            }
                            if let statusMessage = content.statusMessage {
                                Text(statusMessage)
                                    .font(AppTheme.Typography.caption)
                                    .foregroundStyle(AppTheme.mutedInk)
                            }
                        }

                        ForEach(content.value) { card in
                            InsightPanel(card: card)
                        }
                    case .unavailable(let message), .failure(let message):
                        unsupportedPanel(message: message)
                    }
                }
                .padding(AppTheme.Spacing.lg)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("AI Insights")
            .toolbarTitleDisplayMode(.inline)
        }
        .task(id: appContext.insightsFingerprint) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await appContext.loadInsights()
        }
    }

    private var summaryHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("This month")
                .font(AppTheme.Typography.headline)
            Text(CurrencyFormatter.string(from: appContext.monthlySummary.totalSpent))
                .font(AppTheme.Typography.heroValue)
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("Across \(appContext.monthlySummary.transactionCount) entries")
                .font(.title3.weight(.semibold))
            Text("Insights are generated from processed monthly summaries rather than raw logs.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .finSightCard()
    }

    private func unsupportedPanel(message: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("AI unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(AppTheme.Typography.headline)
            Text(message)
                .foregroundStyle(AppTheme.mutedInk)
            Button("Retry") {
                Task {
                    await appContext.loadInsights(forceRefresh: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
        }
        .finSightCard()
    }
}

private struct InsightPanel: View {
    let card: InsightCard

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label(card.kind.title, systemImage: card.kind.systemImage)
                .font(AppTheme.Typography.headline)
                .foregroundStyle(AppTheme.ink)

            FinSightMarkdownView(markdown: card.markdown, style: .aiInsight)

            if card.markdown.isEmpty {
                FinSightTypingIndicator()
            }
        }
        .finSightCard(surface: panelTint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.kind.title) insight")
    }

    private var panelTint: Color {
        switch card.kind {
        case .budgeting:
            AppTheme.cardTintBudget
        case .risk:
            AppTheme.cardTintRisk
        case .growth:
            AppTheme.cardTintGrowth
        }
    }
}
