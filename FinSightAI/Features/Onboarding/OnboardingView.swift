import SwiftUI
import UserNotifications

/// First-run setup: who you are, region and currency, income, 1–3 goals, opt-in sample data and
/// reminders, and how the on-device AI works. Nothing is saved until the last step.
struct OnboardingView: View {
    @Environment(AppContext.self) private var appContext
    @State private var draft = OnboardingDraft()
    @State private var step: OnboardingDraft.Step
    @State private var saving = false
    @State private var completed = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, role, income, goalName(UUID), goalAmount(UUID) }

    init(initialStep: OnboardingDraft.Step = .welcome) {
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                        stepContent
                    }
                    .padding(AppTheme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollDismissesKeyboard(.interactively)
                controls
            }
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(AppTheme.primary)
        .interactiveDismissDisabled()
        .sensoryFeedback(.selection, trigger: step)
        .sensoryFeedback(.success, trigger: completed)
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Chrome

    private var progressHeader: some View {
        let total = OnboardingDraft.Step.allCases.count
        let position = step.rawValue + 1
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ProgressView(value: Double(position), total: Double(total))
                .tint(AppTheme.primary)
            Text("Step \(position) of \(total)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedInk)
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.top, AppTheme.Spacing.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Setup progress"))
        .accessibilityValue(Text("Step \(position) of \(total)"))
    }

    private var controls: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if let previous = step.previous {
                Button {
                    go(to: previous)
                } label: {
                    Text("Back").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(saving)
            }
            if let next = step.next {
                Button {
                    go(to: next)
                } label: {
                    Text("Continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!draft.canAdvance(from: step))
                .accessibilityHint(stepRequirement.map { Text($0) } ?? Text(verbatim: ""))
            } else {
                Button {
                    saving = true
                    Task { await finish() }
                } label: {
                    Group {
                        if saving {
                            ProgressView().accessibilityLabel(Text("Saving your plan…"))
                        } else {
                            Text("Start my plan")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!draft.isValid || saving)
            }
        }
        .padding(AppTheme.Spacing.lg)
        .background(.bar)
    }

    /// What still blocks Continue on this step, for VoiceOver; nil once the step is complete.
    private var stepRequirement: LocalizedStringKey? {
        guard !draft.canAdvance(from: step) else { return nil }
        switch step {
        case .income: return "Enter a monthly income greater than zero."
        case .goals: return "Give each goal a name and a target greater than zero."
        default: return nil
        }
    }

    private func go(to target: OnboardingDraft.Step) {
        focusedField = nil
        step = target
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome: welcomeStep
        case .region: regionStep
        case .income: incomeStep
        case .goals: goalsStep
        case .preferences: preferencesStep
        case .privacy: privacyStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(AppTheme.primary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Welcome to FinSight AI")
                    .font(.largeTitle.bold())
                    .foregroundStyle(AppTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text("Intelligent financial decision-making for early-career earners.")
                    .font(.title3)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                featureRow("Track every peso, dollar or yen you spend, in your own currency.", systemImage: "list.bullet.rectangle")
                featureRow("Real-time behavioral nudges & wealth accelerators.", systemImage: "sparkles")
                featureRow("Model compound savings from small habit changes.", systemImage: "slider.horizontal.3")
            }
            .finSightCard()

            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text("What should we call you?")
                    .font(AppTheme.Typography.headline)
                TextField("Your name (optional)", text: $draft.name, prompt: Text("e.g. Mark Santos"))
                    .textContentType(.name)
                    .focused($focusedField, equals: .name)
                    .accessibilityLabel(Text("Your name (optional)"))
                TextField("Role (optional)", text: $draft.role, prompt: Text("e.g. Junior SWE @ Apex Systems"))
                    .textContentType(.jobTitle)
                    .focused($focusedField, equals: .role)
                    .accessibilityLabel(Text("Role (optional)"))
                Text("Shown in your dashboard greeting. Stays on this device.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            .textFieldStyle(.roundedBorder)
            .finSightCard()
        }
    }

    private var regionStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            stepTitle("Your region", subtitle: "FinSight AI uses your device's region to format money and weeks.")
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                LabeledContent("Region") {
                    Text(Locale.current.localizedString(forRegionCode: Locale.current.region?.identifier ?? "") ?? Locale.current.identifier)
                }
                Divider()
                Picker("Currency", selection: $draft.currencyCode) {
                    ForEach(currencyCodes, id: \.self) { code in
                        Text(currencyLabel(code)).tag(code)
                    }
                }
                .pickerStyle(.navigationLink)
                Divider()
                Picker("First day of week", selection: $draft.firstWeekday) {
                    ForEach(1...7, id: \.self) { day in
                        Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                    }
                }
                Text("Amounts use your device's number format. Changing the currency only changes how amounts are shown; it doesn't convert them.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            .finSightCard()
        }
    }

    private var incomeStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            stepTitle("Monthly income", subtitle: "Your take-home pay sets the target your spending is measured against.")
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                TextField("Monthly income", text: $draft.income, prompt: Text(CurrencyFormatter.string(from: 0, currencyCode: draft.currencyCode)))
                    .keyboardType(.decimalPad)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .income)
                    .accessibilityLabel(Text("Monthly income"))
                if let amount = draft.incomeAmount {
                    Text("Target: \(CurrencyFormatter.string(from: amount, currencyCode: draft.currencyCode)) a month")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                } else if !draft.income.isEmpty {
                    Label("Enter a monthly income greater than zero.", systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text("Used for \"% of income spent\" and the buffer remaining on your dashboard. You can add more income sources later in Settings.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            .finSightCard()
        }
    }

    private var goalsStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            stepTitle("Financial goals", subtitle: "Choose 1–3 goals. The simulator counts down to each one.")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(goalSuggestions, id: \.self) { suggestion in
                        Button {
                            applySuggestion(suggestion)
                        } label: {
                            Label(suggestion, systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!draft.canAddGoal && !draft.goals.contains { $0.name.isEmpty })
                    }
                }
            }
            .accessibilityLabel(Text("Goal suggestions"))

            ForEach($draft.goals) { $goal in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack {
                        Text("Goal \((draft.goals.firstIndex { $0.id == goal.id } ?? 0) + 1)")
                            .font(AppTheme.Typography.headline)
                        Spacer()
                        if draft.canRemoveGoal {
                            Button(role: .destructive) {
                                draft.removeGoal(id: goal.id)
                            } label: {
                                Label("Remove goal", systemImage: "minus.circle")
                                    .labelStyle(.iconOnly)
                            }
                        }
                    }
                    TextField("Goal name", text: $goal.name, prompt: Text("e.g. Emergency Reserve"))
                        .focused($focusedField, equals: .goalName(goal.id))
                        .accessibilityLabel(Text("Goal name"))
                    TextField("Target amount", text: $goal.amount, prompt: Text("Target amount"))
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: .goalAmount(goal.id))
                        .accessibilityLabel(Text("Target amount"))
                }
                .textFieldStyle(.roundedBorder)
                .finSightCard()
            }

            if draft.canAddGoal {
                Button {
                    draft.addGoal()
                } label: {
                    Label("Add goal", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
            }
            if !draft.goalsAreValid {
                Text("Give each goal a name and a target greater than zero.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
    }

    private var preferencesStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            stepTitle("Make it yours", subtitle: "Both are optional and off until you turn them on.")
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Toggle(isOn: $draft.loadSampleData) {
                    Label("Load sample data", systemImage: "tray.and.arrow.down.fill")
                }
                .disabled(!appContext.transactions.isEmpty)
                Text("Adds example transactions so you can explore the app. Your income and goals stay exactly as you entered them.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            .finSightCard()
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Toggle(isOn: $draft.enableNotifications) {
                    Label("Enable local reminders", systemImage: "bell.badge.fill")
                }
                Text("Reminders for recurring charges, budget thresholds and a weekly digest, scheduled on this device. iOS asks for permission when you finish setup.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedInk)
            }
            .finSightCard()
        }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            stepTitle("Private, on-device AI", subtitle: "Your data stays on this device.")
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                featureRow("FinSight calculates every insight on this iPhone from your own transactions.", systemImage: "iphone")
                featureRow("On supported devices, Apple Intelligence explains those insights in plain language — without sending your data anywhere.", systemImage: "sparkles")
                featureRow("No account, no cloud AI and no ads. FinSight AI is free.", systemImage: "lock.shield.fill")
            }
            .finSightCard()
            aiStatusCard
        }
    }

    private var aiStatusCard: some View {
        let availability = appContext.capabilityService.aiAvailability
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            if availability.isAvailable {
                Label("Apple Intelligence is ready on this iPhone.", systemImage: "checkmark.seal.fill")
                    .font(AppTheme.Typography.headline)
                    .foregroundStyle(AppTheme.primary)
            } else if let reason = availability.reason {
                Label(reason.title, systemImage: reason.systemImage)
                    .font(AppTheme.Typography.headline)
                Text(reason.message)
                    .foregroundStyle(AppTheme.mutedInk)
                Text("Core insights, budgets and the simulator still work without it.")
                    .font(.footnote)
                    .foregroundStyle(AppTheme.mutedInk)
            }
        }
        .finSightCard(surface: AppTheme.cardTintBudget)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Pieces

    private func stepTitle(_ title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.largeTitle.bold())
                .foregroundStyle(AppTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .foregroundStyle(AppTheme.mutedInk)
        }
    }

    private func featureRow(_ text: LocalizedStringKey, systemImage: String) -> some View {
        Label {
            Text(text).foregroundStyle(AppTheme.ink)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(AppTheme.primary)
        }
    }

    private var goalSuggestions: [String] {
        [String(localized: "Emergency Reserve"), String(localized: "Dev Rig Setup"), String(localized: "Travel")]
    }

    private func applySuggestion(_ suggestion: String) {
        guard !draft.goals.contains(where: { $0.name == suggestion }) else { return }
        if let index = draft.goals.firstIndex(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            draft.goals[index].name = suggestion
            focusedField = .goalAmount(draft.goals[index].id)
        } else if draft.canAddGoal {
            draft.addGoal()
            draft.goals[draft.goals.count - 1].name = suggestion
            focusedField = .goalAmount(draft.goals[draft.goals.count - 1].id)
        }
    }

    private var currencyCodes: [String] {
        var codes = Set(Locale.commonISOCurrencyCodes)
        codes.insert(draft.currencyCode)
        return codes.sorted()
    }

    private func currencyLabel(_ code: String) -> String {
        guard let name = Locale.current.localizedString(forCurrencyCode: code) else { return code }
        return "\(code) – \(name)"
    }

    private func finish() async {
        defer { saving = false }
        do {
            try appContext.completeOnboarding(draft)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        completed = true
        guard draft.enableNotifications else { return }
        // Setup is already saved; a declined or failed permission request only skips reminders.
        do {
            if try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
                try await NudgeScheduler.refresh(snapshot: .make(context: appContext))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
