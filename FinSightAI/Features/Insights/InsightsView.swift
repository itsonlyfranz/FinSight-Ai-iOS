import SwiftUI

struct InsightsView: View {
    @Environment(AppContext.self) private var appContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AI Financial Intelligence")
                            .font(.title2.bold())
                            .foregroundStyle(AppTheme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text("Real-time behavioral nudges & wealth accelerators")
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedInk)
                    }

                    summaryHeader

                    if !appContext.engineInsights.isEmpty {
                        Text("Active AI Insights")
                            .font(AppTheme.Typography.headline)
                            .foregroundStyle(AppTheme.ink)
                            .accessibilityAddTraits(.isHeader)
                    }

                    signalSection

                    narrationSection
                }
                .padding(AppTheme.Spacing.lg)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Insights")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if appContext.hiddenInsightCount > 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Show \(appContext.hiddenInsightCount) hidden", systemImage: "eye") {
                            run { try appContext.restoreHiddenInsights() }
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.error, trigger: errorMessage) { _, new in new != nil }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            try? appContext.reloadTransactions()
        }
        .task(id: appContext.insightsFingerprint) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await appContext.loadInsights()
        }
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
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
            Text(appContext.monthlySummary.spendingTrendDescription)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .finSightCard()
    }

    // MARK: - Deterministic insights

    @ViewBuilder
    private var signalSection: some View {
        if appContext.engineInsights.isEmpty {
            FinSightEmptyState(
                title: appContext.allEngineInsights.isEmpty ? "No insights yet" : "All caught up",
                systemImage: appContext.allEngineInsights.isEmpty ? "chart.bar.doc.horizontal" : "checkmark.seal",
                message: appContext.allEngineInsights.isEmpty
                    ? "Log a few weeks of expenses, and add income and budgets, to see budget, trend and subscription insights."
                    : "You've dismissed or snoozed every insight for now."
            )
            .finSightCard()
        } else {
            ForEach(appContext.engineInsights) { insight in
                InsightSignalCard(
                    insight: insight,
                    onSnooze: { run { try appContext.snoozeInsight(insight) } },
                    onDismiss: { run { try appContext.dismissInsight(insight) } }
                )
            }
        }
    }

    // MARK: - Optional AI narration

    @ViewBuilder
    private var narrationSection: some View {
        switch appContext.insightState {
        case .empty, .idle:
            EmptyView()
        case .loading:
            narrationHeader
            FinSightInsightSkeleton()
        case .available(let content):
            narrationHeader
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
        case .modelUnavailable(let reason):
            AIUnavailablePanel(reason: reason) {
                Task { await appContext.loadInsights(forceRefresh: true) }
            }
        case .unavailable(let message):
            Text("AI narration is optional and isn't available here: \(message)")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.mutedInk)
        case .failure(let message):
            unsupportedPanel(message: message)
        }
    }

    private var narrationHeader: some View {
        Label("AI narration", systemImage: "sparkles")
            .font(AppTheme.Typography.headline)
            .foregroundStyle(AppTheme.ink)
            .padding(.top, AppTheme.Spacing.xs)
    }

    private func unsupportedPanel(message: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("AI narration unavailable", systemImage: "exclamationmark.triangle.fill")
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

/// Why AI narration can't run, what to do about it, and a reminder that the insights above don't need it.
struct AIUnavailablePanel: View {
    let reason: AIUnavailableReason
    var footnote = "The insights above are calculated on your device and don't need AI."
    let onCheckAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label(reason.title, systemImage: reason.systemImage)
                .font(AppTheme.Typography.headline)
                .foregroundStyle(AppTheme.ink)
            Text(reason.message)
                .foregroundStyle(AppTheme.mutedInk)
            if let hint = reason.actionHint {
                Text(hint)
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            Text(footnote)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.mutedInk)
            if reason.isRecoverable {
                Button("Check Again", action: onCheckAgain)
                    .buttonStyle(.bordered)
                    .tint(AppTheme.primary)
            }
        }
        .finSightCard()
        .accessibilityElement(children: .contain)
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
