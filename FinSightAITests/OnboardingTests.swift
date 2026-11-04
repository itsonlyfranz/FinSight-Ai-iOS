import SwiftData
import XCTest
@testable import FinSightAI

@MainActor
final class OnboardingTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeContext() throws -> AppContext {
        let environment = try AppEnvironment.make(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        try environment.appContext.bootstrap()
        return environment.appContext
    }

    private func validDraft() -> OnboardingDraft {
        var draft = OnboardingDraft()
        draft.name = "  Mark Santos "
        draft.role = "Junior SWE @ Apex Systems"
        draft.currencyCode = "PHP"
        draft.firstWeekday = 2
        draft.income = CurrencyFormatter.plainNumberString(from: Decimal(45_000))
        draft.goals = [
            .init(name: "Emergency Reserve", amount: CurrencyFormatter.plainNumberString(from: Decimal(90_000))),
            .init(name: " Travel ", amount: CurrencyFormatter.plainNumberString(from: Decimal(30_000)))
        ]
        return draft
    }

    // MARK: - Draft

    func testDraftStartsWithSampleDataAndRemindersOffAndIsIncomplete() {
        let draft = OnboardingDraft()
        XCTAssertFalse(draft.loadSampleData)
        XCTAssertFalse(draft.enableNotifications)
        XCTAssertEqual(draft.goals.count, 1)
        XCTAssertFalse(draft.isValid)
        XCTAssertTrue(draft.canAdvance(from: .welcome))
        XCTAssertTrue(draft.canAdvance(from: .region))
        XCTAssertFalse(draft.canAdvance(from: .income))
        XCTAssertFalse(draft.canAdvance(from: .goals))
    }

    func testIncomeMustBePositive() {
        var draft = OnboardingDraft()
        for text in ["", "abc", "0", "-5"] {
            draft.income = text
            XCTAssertNil(draft.incomeAmount, text)
            XCTAssertFalse(draft.canAdvance(from: .income), text)
        }
        draft.income = "1200"
        XCTAssertEqual(draft.incomeAmount, 1200)
        XCTAssertTrue(draft.canAdvance(from: .income))
    }

    func testGoalsNeedANameAndPositiveTargetAndStayWithinOneToThree() {
        var draft = validDraft()
        XCTAssertTrue(draft.isValid)

        draft.goals[0].name = "   "
        XCTAssertFalse(draft.goalsAreValid)
        draft.goals[0].name = "Emergency Reserve"
        draft.goals[0].amount = "0"
        XCTAssertFalse(draft.goalsAreValid)
        draft.goals[0].amount = "100"

        draft.addGoal()
        XCTAssertEqual(draft.goals.count, 3)
        XCTAssertFalse(draft.canAddGoal)
        draft.addGoal()
        XCTAssertEqual(draft.goals.count, 3, "never more than three goals")

        draft.goals = [draft.goals[0]]
        XCTAssertFalse(draft.canRemoveGoal)
        draft.removeGoal(id: draft.goals[0].id)
        XCTAssertEqual(draft.goals.count, 1, "never fewer than one goal")

        draft.goals = []
        XCTAssertFalse(draft.goalsAreValid)
    }

    func testStepsRunInOrder() {
        XCTAssertEqual(OnboardingDraft.Step.allCases, [.welcome, .region, .income, .goals, .preferences, .privacy])
        XCTAssertNil(OnboardingDraft.Step.welcome.previous)
        XCTAssertNil(OnboardingDraft.Step.privacy.next)
        XCTAssertEqual(OnboardingDraft.Step.income.next, .goals)
    }

    // MARK: - Completion

    func testFreshInstallNeedsOnboarding() throws {
        let context = try makeContext()
        XCTAssertTrue(context.needsOnboarding)
    }

    func testCompletingSavesSettingsIncomeGoalsAndProfileWithoutSampleData() throws {
        let context = try makeContext()
        try context.completeOnboarding(validDraft(), profileDefaults: defaults)

        XCTAssertFalse(context.needsOnboarding)
        XCTAssertEqual(context.currencyCode, "PHP")
        XCTAssertEqual(context.settings?.firstWeekday, 2)
        XCTAssertEqual(context.incomeSources.map(\.monthlyAmount), [45_000])
        XCTAssertEqual(context.savingsGoals.map(\.name), ["Emergency Reserve", "Travel"])
        XCTAssertEqual(context.savingsGoals.map(\.targetAmount), [90_000, 30_000])
        XCTAssertTrue(context.transactions.isEmpty, "sample data is opt-in")
        XCTAssertEqual(UserProfile.load(from: defaults), UserProfile(name: "Mark Santos", role: "Junior SWE @ Apex Systems"))
    }

    func testOptingInLoadsSampleTransactionsButKeepsTheEnteredPlan() throws {
        let context = try makeContext()
        var draft = validDraft()
        draft.loadSampleData = true
        try context.completeOnboarding(draft, profileDefaults: defaults)

        XCTAssertFalse(context.transactions.isEmpty)
        XCTAssertEqual(context.incomeSources.count, 1)
        XCTAssertEqual(context.savingsGoals.map(\.name), ["Emergency Reserve", "Travel"])
        XCTAssertTrue(context.budgets.isEmpty)
    }

    func testIncompleteDraftIsRejectedAndNothingIsSaved() throws {
        let context = try makeContext()
        var draft = validDraft()
        draft.income = ""
        XCTAssertThrowsError(try context.completeOnboarding(draft, profileDefaults: defaults)) { error in
            XCTAssertEqual(error as? OnboardingError, .incomplete)
        }
        XCTAssertTrue(context.needsOnboarding)
        XCTAssertTrue(context.incomeSources.isEmpty)
        XCTAssertTrue(context.savingsGoals.isEmpty)
        XCTAssertNil(defaults.string(forKey: UserProfile.nameKey))
    }

    func testOnboardingCannotRunTwice() throws {
        let context = try makeContext()
        try context.completeOnboarding(validDraft(), profileDefaults: defaults)
        XCTAssertThrowsError(try context.completeOnboarding(validDraft(), profileDefaults: defaults)) { error in
            XCTAssertEqual(error as? OnboardingError, .alreadyCompleted)
        }
        XCTAssertEqual(context.savingsGoals.count, 2)
    }

    func testPeopleWithExistingDataSkipOnboarding() throws {
        let environment = try AppEnvironment.make(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = environment.appContext
        context.modelContext.insert(IncomeSource(name: "Salary", monthlyAmount: 1_000))
        try context.modelContext.save()
        try context.bootstrap()
        XCTAssertFalse(context.needsOnboarding)
        XCTAssertEqual(context.incomeSources.count, 1, "bootstrap loads the stored plan")
    }

    // MARK: - Profile

    func testProfileInitials() {
        XCTAssertEqual(UserProfile(name: "Mark Santos").initials, "MS")
        XCTAssertEqual(UserProfile(name: "  ana  ").initials, "A")
        XCTAssertEqual(UserProfile(name: "Juan dela Cruz").initials, "JD")
        XCTAssertNil(UserProfile(name: "   ").initials)
    }
}

final class ThemePaletteTests: XCTestCase {
    func testAndroidPaletteIdentifiersAndFallback() {
        XCTAssertEqual(ThemePalette.allCases.map(\.rawValue), ["DECK_EMERALD", "CYBER_SLATE", "MIDNIGHT_BLUE"])
        for palette in ThemePalette.allCases {
            XCTAssertEqual(ThemePalette.stored(palette.rawValue), palette)
        }
        XCTAssertEqual(ThemePalette.stored("unknown"), .deckEmerald)
        XCTAssertEqual(ThemePalette.stored(nil), .deckEmerald)
    }

    func testAndroidDarkColoursArePreserved() {
        XCTAssertEqual(ThemePalette.deckEmerald.colors.primary.dark, 0x10B981)
        XCTAssertEqual(ThemePalette.cyberSlate.colors.primary.dark, 0x8B5CF6)
        XCTAssertEqual(ThemePalette.midnightBlue.colors.primary.dark, 0x3B82F6)
        XCTAssertEqual(ThemePalette.deckEmerald.colors.background.dark, 0x0B0F17)
        XCTAssertEqual(ThemePalette.cyberSlate.colors.background.dark, 0x090D16)
        XCTAssertEqual(ThemePalette.midnightBlue.colors.background.dark, 0x060B16)
    }

    func testSwitchingThemeIsReadFromDefaults() {
        let original = UserDefaults.standard.string(forKey: ThemePalette.storageKey)
        defer { UserDefaults.standard.set(original, forKey: ThemePalette.storageKey) }
        UserDefaults.standard.set("MIDNIGHT_BLUE", forKey: ThemePalette.storageKey)
        XCTAssertEqual(ThemePalette.current, .midnightBlue)
        UserDefaults.standard.set("CYBER_SLATE", forKey: ThemePalette.storageKey)
        XCTAssertEqual(ThemePalette.current, .cyberSlate)
    }

    /// WCAG AA: 4.5:1 for body text, 3:1 for large text and controls, in light and dark.
    func testEveryPaletteMeetsContrastInLightAndDark() {
        for palette in ThemePalette.allCases {
            let colors = palette.colors
            for (card, background, ink, muted, primary) in [
                (colors.card.light, colors.background.light, ThemeColors.ink.light, ThemeColors.mutedInk.light, colors.primary.light),
                (colors.card.dark, colors.background.dark, ThemeColors.ink.dark, ThemeColors.mutedInk.dark, colors.primary.dark)
            ] {
                for surface in [card, background] {
                    XCTAssertGreaterThanOrEqual(ContrastRatio.between(ink, surface), 4.5, "\(palette) ink")
                    XCTAssertGreaterThanOrEqual(ContrastRatio.between(muted, surface), 4.5, "\(palette) muted")
                    XCTAssertGreaterThanOrEqual(ContrastRatio.between(primary, surface), 3.0, "\(palette) primary")
                }
            }
            XCTAssertGreaterThanOrEqual(ContrastRatio.between(colors.primary.light, colors.card.light), 4.5, "\(palette) light primary text")
            XCTAssertGreaterThanOrEqual(ContrastRatio.between(colors.bright, colors.deep), 4.5, "\(palette) hero accent")
            XCTAssertGreaterThanOrEqual(ContrastRatio.between(0xF8FAFC, colors.deep), 4.5, "\(palette) hero text")
        }
    }

    func testMixBlendsChannels() {
        XCTAssertEqual(AdaptiveHex.mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
        XCTAssertEqual(AdaptiveHex.mix(0x102030, 0x102030, 0.3), 0x102030)
        XCTAssertEqual(ContrastRatio.between(0x000000, 0xFFFFFF), 21, accuracy: 0.01)
    }
}

final class MonthlyTrendTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testSixMonthsEndingAtTheSelectedMonthIncludingEmptyMonths() {
        let entries = [
            LedgerEntry(amount: 100, category: .groceries, date: date(2026, 11, 3)),
            LedgerEntry(amount: 50, category: .dining, date: date(2026, 11, 20)),
            LedgerEntry(amount: 70, category: .transport, date: date(2026, 8, 1)),
            LedgerEntry(amount: 999, category: .bills, date: date(2026, 4, 30)), // outside the window
            LedgerEntry(amount: 500, kind: .income, category: .other, date: date(2026, 11, 1)),
            LedgerEntry(amount: 300, category: .savings, date: date(2026, 11, 2))
        ]
        let totals = MonthlyTrend.totals(entries: entries, endingAt: date(2026, 11, 15), calendar: calendar)
        XCTAssertEqual(totals.count, 6)
        XCTAssertEqual(totals.first?.monthStart, calendar.date(from: DateComponents(year: 2026, month: 6, day: 1)))
        XCTAssertEqual(totals.map(\.total), [0, 0, 70, 0, 0, 150], "income and savings never count as spending")
    }

    func testAvailableMonthsRunFromTheEarliestEntryToNow() {
        let entries = [LedgerEntry(amount: 10, category: .dining, date: date(2026, 9, 10))]
        let months = MonthlyTrend.availableMonths(entries: entries, now: date(2026, 11, 4), calendar: calendar)
        XCTAssertEqual(months.map { calendar.component(.month, from: $0) }, [11, 10, 9])
        XCTAssertEqual(MonthlyTrend.availableMonths(entries: [], now: date(2026, 11, 4), calendar: calendar).count, 1)
        let old = [LedgerEntry(amount: 10, category: .dining, date: date(2020, 1, 1))]
        XCTAssertEqual(MonthlyTrend.availableMonths(entries: old, now: date(2026, 11, 4), limit: 24, calendar: calendar).count, 24)
    }
}
