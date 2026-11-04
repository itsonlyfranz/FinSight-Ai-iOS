import Foundation
import os
import SwiftData

enum OnboardingError: LocalizedError {
    case incomplete
    case alreadyCompleted

    var errorDescription: String? {
        switch self {
        case .incomplete: String(localized: "Enter a positive monthly income and 1–3 named goals with positive targets.")
        case .alreadyCompleted: String(localized: "Setup is already complete.")
        }
    }
}

extension AppContext {
    /// Whether the first-run flow should be shown.
    var needsOnboarding: Bool {
        guard let settings else { return false }
        return !settings.hasCompletedOnboarding
    }

    /// People who already had data before onboarding existed skip it rather than being asked again.
    func markExistingUserOnboarded() throws {
        guard let settings, !settings.hasCompletedOnboarding else { return }
        guard !hasNoData || !incomeSources.isEmpty || !savingsGoals.isEmpty || !budgets.isEmpty else { return }
        settings.hasCompletedOnboarding = true
        settings.updatedAt = .now
        try modelContext.save()
    }

    /// Commits every first-run choice in one save; if it fails nothing is kept and onboarding can
    /// be retried. Income and goals are only added to an empty plan, so nothing is duplicated.
    func completeOnboarding(_ draft: OnboardingDraft, profileDefaults: UserDefaults = .standard, now: Date = .now) throws {
        guard let settings else { throw OnboardingError.incomplete }
        guard !settings.hasCompletedOnboarding else { throw OnboardingError.alreadyCompleted }
        guard draft.isValid, let income = draft.incomeAmount else { throw OnboardingError.incomplete }

        settings.currencyCode = AppSettings.normalizedCurrencyCode(draft.currencyCode)
        settings.firstWeekday = AppSettings.normalizedWeekday(draft.firstWeekday)
        if incomeSources.isEmpty {
            modelContext.insert(IncomeSource(name: String(localized: "Monthly income"), monthlyAmount: income))
        }
        if savingsGoals.isEmpty {
            for goal in draft.goals {
                guard let target = AmountParser.parse(goal.amount) else { continue }
                modelContext.insert(SavingsGoal(name: goal.name.trimmingCharacters(in: .whitespacesAndNewlines), targetAmount: target))
            }
        }
        // Sample data adds example transactions only: the person's own income and goals stay theirs.
        if draft.loadSampleData && transactions.isEmpty {
            for record in SampleData.makeTransactions(now: now) { modelContext.insert(record) }
        }
        settings.hasCompletedOnboarding = true
        settings.updatedAt = now
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        UserProfile(name: draft.name, role: draft.role).save(to: profileDefaults)
        applyCurrencySetting()
        do {
            try reloadTransactions()
        } catch {
            Logger(subsystem: "com.finsightai.app", category: "Onboarding").error("Reload after setup failed: \(error.localizedDescription)")
        }
    }
}

#if DEBUG
extension AppContext {
    /// Debug-only launch hook (`-FinSightDemoSeed YES`) that finishes onboarding with the Android
    /// sample persona and sample data, so screenshots and UI checks can start past setup.
    func applyDebugDemoSeedIfRequested(defaults: UserDefaults = .standard) throws {
        guard defaults.bool(forKey: "FinSightDemoSeed"), needsOnboarding else { return }
        var draft = OnboardingDraft()
        draft.name = "Mark Santos"
        draft.role = "Junior SWE @ Apex Systems"
        draft.income = CurrencyFormatter.plainNumberString(from: Decimal(45_000))
        draft.goals = [.init(name: String(localized: "Emergency Reserve"), amount: CurrencyFormatter.plainNumberString(from: Decimal(90_000)))]
        draft.loadSampleData = true
        try completeOnboarding(draft)
        try loadSamplePlanning()
    }
}
#endif
