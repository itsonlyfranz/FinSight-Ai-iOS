import SwiftUI

struct SimulatorView: View {
    @Environment(AppContext.self) private var appContext
    @State private var explanationContext: SimulationNarrationContext?
    @State private var showsBand = true
    /// Typed text for the starting balance, committed to the scenario when editing ends so the
    /// field isn't reformatted (and the cursor moved) on every keystroke.
    @State private var startingBalanceText = ""
    @FocusState private var startingBalanceFocused: Bool

    var body: some View {
        let scenario = appContext.workingScenario.normalized
        let result = appContext.simulate(scenario)
        let context = appContext.narrationContext(for: scenario, result: result)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    heroCard(scenario: scenario, result: result)
                    if appContext.runRateBaseline.isEmpty {
                        emptyBaselineCard
                    } else {
                        baselineCard
                        categoryCutsCard(result: result)
                    }
                    savingsCard(scenario: scenario)
                    recurringControlsCard(result: result)
                    projectionCard(result: result)
                    goalsCard(result: result)
                    ScenarioLibraryCard()
                    summaryCard(scenario: scenario, result: result)
                    explanationCard(context: explanationContext ?? context)
                }
                .padding(AppTheme.Spacing.lg)
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Forward Simulator")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reset", systemImage: "arrow.counterclockwise") { appContext.resetWorkingScenario() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { startingBalanceFocused = false }
                }
            }
        }
        .task(id: context) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            explanationContext = context
        }
        .task(id: explanationContext) {
            guard let explanationContext else { return }
            await appContext.loadSimulationExplanation(context: explanationContext)
        }
    }

    // MARK: - Cards

    private func heroCard(scenario: SimulationScenario, result: SimulationResult) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Monthly freed cashflow")
                .font(.headline)
                .foregroundStyle(AppTheme.onElevated.opacity(0.85))
            Text(CurrencyFormatter.string(from: result.monthlySavings))
                .font(AppTheme.Typography.heroValue)
                .foregroundStyle(AppTheme.accentOnElevated)
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .accessibilityLabel("Projected monthly savings")
                .accessibilityValue(CurrencyFormatter.string(from: result.monthlySavings))
                .contentTransition(.numericText())
                .motionSafeAnimation(.spring(duration: 0.3), value: result.monthlySavings)
            Text("freed each month. After 12 months at \(SimulationFacts.percent(scenario.annualYieldPercent)) a year that grows to \(CurrencyFormatter.string(from: result.twelveMonths)).")
                .foregroundStyle(AppTheme.onElevated.opacity(0.88))
        }
        .finSightCard(surface: AppTheme.surfaceElevated)
        .accessibilityElement(children: .contain)
    }

    private var baselineCard: some View {
        let baseline = appContext.runRateBaseline
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Label("Your typical month", systemImage: "calendar")
                .font(.headline)
            Text(CurrencyFormatter.string(from: baseline.monthlyTotal))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            Text("\(CurrencyFormatter.string(from: baseline.discretionaryTotal)) everyday spending, scaled from your last 30 days, plus \(CurrencyFormatter.string(from: baseline.recurringTotal)) of recurring charges. Transfers and savings are not counted.")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.mutedInk)
            if !baseline.excludedOneOffs.isEmpty {
                Label(
                    "Left out as one-off: \(baseline.excludedOneOffs.map { "\($0.merchant.isEmpty ? $0.category.localizedTitle : $0.merchant) \(CurrencyFormatter.string(from: $0.amount))" }.joined(separator: ", "))",
                    systemImage: "minus.circle"
                )
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .finSightCard()
    }

    private var emptyBaselineCard: some View {
        FinSightEmptyState(
            title: "No spending yet",
            systemImage: "chart.bar.doc.horizontal",
            message: "Add a few transactions and your categories appear here as sliders. You can still try a daily savings amount below."
        )
        .finSightCard()
    }

    private func categoryCutsCard(result: SimulationResult) -> some View {
        let lines = appContext.runRateBaseline.cuttableLines
        return VStack(alignment: .leading, spacing: 18) {
            Label("Lifestyle Inflation Levers", systemImage: "scissors")
                .font(.headline)
            if lines.isEmpty {
                Text("All of your spending is recurring. Pause charges below to see what they would save.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            ForEach(lines) { line in
                let percent = appContext.workingScenario.cutPercent(for: line.category)
                let saved = result.categorySavings.first { $0.category == line.category }?.saved ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(line.category.localizedTitle, systemImage: line.category.symbolName)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(percent)%")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    Text("\(CurrencyFormatter.string(from: line.discretionary)) a month · saves \(CurrencyFormatter.string(from: saved))")
                        .font(AppTheme.Typography.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.mutedInk)
                    Slider(value: cutBinding(for: line.category), in: 0...100, step: 5)
                        .accessibilityLabel("\(line.category.localizedTitle) cut")
                        .accessibilityValue("\(percent) percent, saves \(CurrencyFormatter.string(from: saved)) a month")
                }
            }
        }
        .finSightCard()
    }

    private func savingsCard(scenario: SimulationScenario) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Daily savings").font(.headline)
                Text(CurrencyFormatter.string(from: scenario.dailySavings))
                    .font(.title3.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                    .motionSafeAnimation(.spring(duration: 0.3), value: scenario.dailySavings)
                Slider(value: dailySavingsBinding, in: 0...500, step: 10)
                    .accessibilityLabel("Daily savings")
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Yield on savings (APY)").font(.headline)
                Text(SimulationFacts.percent(scenario.annualYieldPercent))
                    .font(.title3.weight(.semibold)).monospacedDigit()
                Slider(value: yieldBinding, in: 0...12, step: 0.25)
                    .accessibilityLabel("Annual percentage yield")
                    .accessibilityValue(SimulationFacts.percent(scenario.annualYieldPercent))
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Starting balance").font(.headline)
                TextField("Starting balance", text: $startingBalanceText)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .focused($startingBalanceFocused)
                    .onSubmit(commitStartingBalance)
                    .onChange(of: startingBalanceFocused) { _, focused in
                        if !focused { commitStartingBalance() }
                    }
                    .onChange(of: scenario.startingBalance, initial: true) { _, value in
                        if !startingBalanceFocused { startingBalanceText = startingBalanceDisplay(value) }
                    }
                Text("Money you've already set aside that the projection grows from.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }

            Picker("Timeline", selection: horizonBinding) {
                ForEach([12, 24, 36, 60], id: \.self) { months in
                    Text(months == 60 ? "5 yr" : "\(months) mo").tag(months)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Projection length")
        }
        .finSightCard()
    }

    private func recurringControlsCard(result: SimulationResult) -> some View {
        let charges = appContext.runRateBaseline.recurringCharges
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Label("Recurring expenses", systemImage: "repeat.circle.fill")
                    .font(.headline)
                Spacer()
                Text(CurrencyFormatter.string(from: result.pausedRecurringSavings))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(AppTheme.primary)
                    .accessibilityLabel("Paused charges save \(CurrencyFormatter.string(from: result.pausedRecurringSavings)) a month")
            }

            if charges.isEmpty {
                FinSightEmptyState(
                    title: "No recurring charges",
                    systemImage: "calendar.badge.clock",
                    message: "Set recurring expenses from Transactions to model long-term savings here."
                )
            } else {
                Text("Charges are on by default. Turn one off to see what pausing it would save.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
                ForEach(charges) { charge in
                    let isIncluded = !appContext.workingScenario.pausedRecurringIDs.contains(charge.id)
                    Toggle(isOn: recurringBinding(for: charge.id)) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(charge.name).font(.subheadline.weight(.semibold))
                            Text(CurrencyFormatter.string(from: charge.monthlyAmount) + (isIncluded ? "/mo" : "/mo - paused"))
                                .font(AppTheme.Typography.caption)
                                .foregroundStyle(AppTheme.mutedInk)
                        }
                    }
                    .toggleStyle(.switch)
                }
            }
        }
        .finSightCard()
    }

    private func projectionCard(result: SimulationResult) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Projected savings").font(.headline)

            ProjectionChart(result: result, showsBand: showsBand)

            if result.hasUncertaintyBand {
                Toggle("Show likely range", isOn: $showsBand)
                    .font(.subheadline)
                Text("The shaded range covers the middle 80% of outcomes, from how much your everyday spending has swung month to month.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            } else {
                Text("A likely range appears once you have three complete months of spending.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }

            ForEach(Array(result.milestones.enumerated()), id: \.element.id) { index, point in
                if index > 0 { Divider().overlay(AppTheme.divider) }
                projectionRow(label: "\(point.month) months", point: point)
            }
        }
        .finSightCard()
    }

    private func goalsCard(result: SimulationResult) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("Financial Goals Countdown", systemImage: "flag.checkered")
                .font(.headline)
            if result.goals.isEmpty {
                Text("Create a savings goal to see how much sooner this plan gets you there.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            } else {
                ForEach(result.goals) { goal in
                    GoalCountdownRow(goal: goal)
                    if goal.id != result.goals.last?.id { Divider().overlay(AppTheme.divider) }
                }
                Text("Each goal is measured on its own: its usual monthly pace plus what this plan frees.")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .finSightCard()
    }

    /// The explanation written by code, always shown so the screen makes sense without AI.
    private func summaryCard(scenario: SimulationScenario, result: SimulationResult) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Label("Plan summary", systemImage: "text.alignleft")
                .font(.headline)
            FinSightMarkdownView(
                markdown: SimulationSummaryText.content(scenario: scenario, result: result).markdown,
                style: .simulatorExplanation
            )
        }
        .finSightCard()
    }

    private func explanationCard(context: SimulationNarrationContext) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Label("AI Milestone Context", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                FinSightStreamingRefreshControl(
                    isRefreshing: appContext.isSimulationRefreshInFlight || simulatorExplanationIsRefreshing,
                    action: {
                        Task { await appContext.loadSimulationExplanation(context: context, forceRefresh: true) }
                    },
                    progressText: "Streaming...",
                    buttonStyleKind: .bordered
                )
            }

            switch appContext.simulatorExplanationState {
            case .idle, .loading:
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    FinSightTypingIndicator()
                    Text("Preparing scenario explanation…")
                        .foregroundStyle(AppTheme.mutedInk)
                }
            case .available(let content):
                if content.isRefreshing {
                    FinSightStatusLine("Streaming latest explanation…")
                }
                FinSightMarkdownView(markdown: content.value, style: .simulatorExplanation)
                FinSightStatusLine(text: RelativeTimestampFormatter.updatedString(for: content.lastUpdated))
                if let statusMessage = content.statusMessage {
                    Text(statusMessage)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                }
            case .modelUnavailable(let reason):
                AIUnavailablePanel(
                    reason: reason,
                    footnote: "The plan summary above is calculated on your device and doesn't need AI."
                ) {
                    Task { await appContext.loadSimulationExplanation(context: context, forceRefresh: true) }
                }
            case .unavailable(let message), .failure(let message):
                Text("AI explanation is optional and isn't available here: \(message)")
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .finSightCard()
    }

    private var simulatorExplanationIsRefreshing: Bool {
        if case .available(let content) = appContext.simulatorExplanationState {
            return content.isRefreshing
        }
        return false
    }

    private func projectionRow(label: LocalizedStringKey, point: ProjectionPoint) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if point.interest > 0 {
                    Text("includes \(CurrencyFormatter.string(from: point.interest)) interest")
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                }
            }
            Spacer()
            Text(CurrencyFormatter.string(from: point.balance))
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText())
                .motionSafeAnimation(.spring(duration: 0.3), value: point.balance)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Bindings

    private func cutBinding(for category: SpendingCategory) -> Binding<Double> {
        Binding {
            Double(appContext.workingScenario.cutPercent(for: category))
        } set: { value in
            appContext.workingScenario.setCut(Int(value.rounded()), for: category)
        }
    }

    private var dailySavingsBinding: Binding<Double> {
        Binding {
            appContext.workingScenario.dailySavings.doubleValue
        } set: { value in
            appContext.workingScenario.dailySavings = Decimal(Int(value.rounded()))
        }
    }

    private var yieldBinding: Binding<Double> {
        Binding {
            appContext.workingScenario.annualYieldPercent.doubleValue
        } set: { value in
            // Quarter-point steps, kept exact by working in hundredths.
            appContext.workingScenario.annualYieldPercent = Decimal(Int((value * 100).rounded())) / 100
        }
    }

    private func startingBalanceDisplay(_ value: Decimal) -> String {
        value == 0 ? "" : CurrencyFormatter.plainNumberString(from: value)
    }

    /// Stores the typed amount (empty means zero); text that isn't a number reverts to the stored balance.
    private func commitStartingBalance() {
        let trimmed = startingBalanceText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            appContext.workingScenario.startingBalance = 0
        } else if let value = trimmed.parsedAmount {
            appContext.workingScenario.startingBalance = max(0, value)
        }
        startingBalanceText = startingBalanceDisplay(appContext.workingScenario.startingBalance)
    }

    private var horizonBinding: Binding<Int> {
        Binding {
            appContext.workingScenario.horizonMonths
        } set: { value in
            appContext.workingScenario.horizonMonths = value
        }
    }

    /// On = the charge keeps running; off = paused in this scenario.
    private func recurringBinding(for id: UUID) -> Binding<Bool> {
        Binding {
            !appContext.workingScenario.pausedRecurringIDs.contains(id)
        } set: { isIncluded in
            appContext.workingScenario.setRecurring(id, included: isIncluded)
        }
    }
}

private struct GoalCountdownRow: View {
    let goal: GoalCountdown

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(goal.name.isEmpty ? String(localized: "Goal") : goal.name).font(.subheadline.weight(.semibold))
                Spacer()
                Label(statusTitle, systemImage: statusSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusTint)
            }
            Text(detail)
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch goal.status {
        case .reached: "Funded"
        case .noPace: "No pace"
        case .onTrack: "On track"
        case .behind: "Behind"
        }
    }

    private var statusSymbol: String {
        switch goal.status {
        case .reached: "checkmark.seal.fill"
        case .noPace: "pause.circle.fill"
        case .onTrack: "checkmark.circle.fill"
        case .behind: "exclamationmark.circle.fill"
        }
    }

    private var statusTint: Color {
        switch goal.status {
        case .reached, .onTrack: .green
        case .noPace: AppTheme.mutedInk
        case .behind: .orange
        }
    }

    private var detail: String {
        switch goal.status {
        case .reached:
            return String(localized: "Already funded.")
        case .noPace:
            return String(localized: "\(CurrencyFormatter.string(from: goal.remaining)) to go. Nothing is saved toward it yet, so it won't be funded.")
        case .onTrack, .behind:
            let months = goal.planMonths ?? 0
            var parts = [String(localized: "\(months) months to go")]
            if let fundedBy = goal.fundedBy { parts.append(String(localized: "Funded by \(MonthFormatter.label(for: fundedBy)).")) }
            if let sooner = goal.monthsSooner, sooner > 0 {
                parts.append(String(localized: "\(sooner) months sooner."))
            }
            parts.append(String(localized: "\(CurrencyFormatter.string(from: goal.remaining)) remaining."))
            if goal.status == .behind, let targetDate = goal.targetDate {
                parts.append(String(localized: "Misses its \(MonthFormatter.label(for: targetDate)) target."))
            }
            return parts.joined(separator: " ")
        }
    }
}
