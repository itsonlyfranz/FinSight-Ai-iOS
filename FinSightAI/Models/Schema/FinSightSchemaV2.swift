import Foundation
import SwiftData

/// Schema V2 — the current data model.
///
/// CloudKit-compatible by construction so iCloud sync can be switched on later without another
/// migration: no `.unique` constraints (uniqueness is enforced by `StoreIntegrity` instead), every
/// attribute has a default value or is optional, and every relationship is optional with an inverse.
///
/// Money is persisted as exact integers (`Money.scale` fractional digits) in `*Scaled` properties
/// and exposed as `Decimal` — see `Money`.
enum FinSightSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    static var models: [any PersistentModel.Type] {
        [
            TransactionRecord.self,
            RecurringExpenseRecord.self,
            AIResponseCacheRecord.self,
            IncomeSource.self,
            Budget.self,
            SavingsGoal.self,
            GoalContribution.self,
            AppSettings.self
        ]
    }

    // MARK: - Transactions

    @Model
    final class TransactionRecord {
        var id: UUID = UUID()
        /// Non-negative magnitude in `Money.scale` fixed point. Direction comes from `kind`.
        var amountScaled: Int = 0
        var kindRawValue: String = TransactionKind.expense.rawValue
        var merchantNameStorage: String?
        var categoryRawValue: String = SpendingCategory.other.rawValue
        var date: Date = Date.now
        var note: String = ""
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        init(
            id: UUID = UUID(),
            amount: Decimal,
            kind: TransactionKind = .expense,
            merchantName: String = "",
            category: SpendingCategory,
            date: Date,
            note: String = "",
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.amountScaled = Money.scaled(amount)
            self.kindRawValue = kind.rawValue
            self.merchantNameStorage = merchantName
            self.categoryRawValue = category.rawValue
            self.date = date
            self.note = note
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// Exact, non-negative magnitude.
        var amount: Decimal {
            get { Money.decimal(fromScaled: amountScaled) }
            set { amountScaled = Money.scaled(newValue) }
        }

        var kind: TransactionKind {
            get { TransactionKind(rawValue: kindRawValue) ?? .expense }
            set { kindRawValue = newValue.rawValue }
        }

        /// Cash-flow effect: negative for expenses, positive for income, zero for transfers.
        var signedAmount: Decimal { kind.signedAmount(for: amount) }

        /// True for expenses outside the savings category (savings are set aside, not spent).
        var countsAsSpending: Bool { kind == .expense && category.countsAsSpending }

        var countsAsIncome: Bool { kind == .income }

        var category: SpendingCategory {
            get { SpendingCategory(rawValue: categoryRawValue) ?? .other }
            set { categoryRawValue = newValue.rawValue }
        }

        var merchantName: String {
            get { merchantNameStorage ?? "" }
            set { merchantNameStorage = newValue }
        }
    }

    @Model
    final class RecurringExpenseRecord {
        var id: UUID = UUID()
        var merchantNameStorage: String?
        var amountScaled: Int = 0
        var categoryRawValue: String = SpendingCategory.bills.rawValue
        var expectedDay: Int = 1
        var isActive: Bool = true
        var note: String = ""
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        init(
            id: UUID = UUID(),
            merchantName: String,
            amount: Decimal,
            category: SpendingCategory,
            expectedDay: Int,
            isActive: Bool = true,
            note: String = "",
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.merchantNameStorage = merchantName
            self.amountScaled = Money.scaled(amount)
            self.categoryRawValue = category.rawValue
            self.expectedDay = min(max(expectedDay, 1), 31)
            self.isActive = isActive
            self.note = note
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var amount: Decimal {
            get { Money.decimal(fromScaled: amountScaled) }
            set { amountScaled = Money.scaled(newValue) }
        }

        var merchantName: String {
            get { merchantNameStorage ?? "" }
            set { merchantNameStorage = newValue }
        }

        var category: SpendingCategory {
            get { SpendingCategory(rawValue: categoryRawValue) ?? .other }
            set { categoryRawValue = newValue.rawValue }
        }
    }

    // MARK: - AI cache

    @Model
    final class AIResponseCacheRecord {
        /// Unique by convention (enforced at app level; CloudKit forbids `.unique`).
        var cacheKey: String = ""
        var featureRawValue: String = AICacheFeature.monthlyInsights.rawValue
        var sourceFingerprint: String = ""
        var payload: String = ""
        var generatedAt: Date = Date.now
        var lastAutoRefreshDayKey: String?
        var providerIdentifier: String = ""
        var failureMessage: String?
        var updatedAt: Date = Date.now

        init(
            cacheKey: String,
            feature: AICacheFeature,
            sourceFingerprint: String,
            payload: String,
            generatedAt: Date,
            lastAutoRefreshDayKey: String? = nil,
            providerIdentifier: String,
            failureMessage: String? = nil,
            updatedAt: Date = .now
        ) {
            self.cacheKey = cacheKey
            self.featureRawValue = feature.rawValue
            self.sourceFingerprint = sourceFingerprint
            self.payload = payload
            self.generatedAt = generatedAt
            self.lastAutoRefreshDayKey = lastAutoRefreshDayKey
            self.providerIdentifier = providerIdentifier
            self.failureMessage = failureMessage
            self.updatedAt = updatedAt
        }

        var feature: AICacheFeature {
            get { AICacheFeature(rawValue: featureRawValue) ?? .monthlyInsights }
            set { featureRawValue = newValue.rawValue }
        }
    }

    // MARK: - Income, budgets, goals

    /// A recurring monthly income (salary, allowance, …). The sum of the active sources is the
    /// user's monthly income.
    @Model
    final class IncomeSource {
        var id: UUID = UUID()
        var name: String = ""
        var monthlyAmountScaled: Int = 0
        var isActive: Bool = true
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        init(
            id: UUID = UUID(),
            name: String,
            monthlyAmount: Decimal,
            isActive: Bool = true,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.name = name
            self.monthlyAmountScaled = Money.scaled(monthlyAmount)
            self.isActive = isActive
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var monthlyAmount: Decimal {
            get { Money.decimal(fromScaled: monthlyAmountScaled) }
            set { monthlyAmountScaled = Money.scaled(newValue) }
        }
    }

    /// A monthly spending limit for one category. At most one budget exists per category
    /// (enforced at app level by `StoreIntegrity`).
    @Model
    final class Budget {
        var id: UUID = UUID()
        var categoryRawValue: String = SpendingCategory.other.rawValue
        var monthlyAmountScaled: Int = 0
        /// When true, unspent budget from previous months carries over into the current month.
        var rolloverEnabled: Bool = false
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        init(
            id: UUID = UUID(),
            category: SpendingCategory,
            monthlyAmount: Decimal,
            rolloverEnabled: Bool = false,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.categoryRawValue = category.rawValue
            self.monthlyAmountScaled = Money.scaled(monthlyAmount)
            self.rolloverEnabled = rolloverEnabled
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var category: SpendingCategory {
            get { SpendingCategory(rawValue: categoryRawValue) ?? .other }
            set { categoryRawValue = newValue.rawValue }
        }

        var monthlyAmount: Decimal {
            get { Money.decimal(fromScaled: monthlyAmountScaled) }
            set { monthlyAmountScaled = Money.scaled(newValue) }
        }
    }

    @Model
    final class SavingsGoal {
        var id: UUID = UUID()
        var name: String = ""
        var targetAmountScaled: Int = 0
        /// Running total of contributions plus any opening balance. Kept in step with
        /// `contributions` by `contribute(_:on:note:)`.
        var savedAmountScaled: Int = 0
        var targetDate: Date?
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        @Relationship(deleteRule: .cascade, inverse: \GoalContribution.goal)
        var contributions: [GoalContribution]? = []

        init(
            id: UUID = UUID(),
            name: String,
            targetAmount: Decimal,
            savedAmount: Decimal = 0,
            targetDate: Date? = nil,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.name = name
            self.targetAmountScaled = Money.scaled(targetAmount)
            self.savedAmountScaled = Money.scaled(savedAmount)
            self.targetDate = targetDate
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        var targetAmount: Decimal {
            get { Money.decimal(fromScaled: targetAmountScaled) }
            set { targetAmountScaled = Money.scaled(newValue) }
        }

        var savedAmount: Decimal {
            get { Money.decimal(fromScaled: savedAmountScaled) }
            set { savedAmountScaled = Money.scaled(newValue) }
        }

        var remainingAmount: Decimal { max(0, targetAmount - savedAmount) }

        var isReached: Bool { targetAmountScaled > 0 && savedAmountScaled >= targetAmountScaled }

        /// Progress from 0 to 1 (clamped); 0 when no target is set.
        var progress: Double {
            guard targetAmountScaled > 0 else { return 0 }
            return min(1, max(0, (savedAmount / targetAmount).doubleValue))
        }

        /// Records a contribution (negative amounts are withdrawals) and updates the saved total.
        @discardableResult
        func contribute(_ amount: Decimal, on date: Date = .now, note: String = "") -> GoalContribution {
            let contribution = GoalContribution(amount: amount, date: date, note: note)
            contribution.goal = self
            if contributions == nil { contributions = [] }
            contributions?.append(contribution)
            savedAmountScaled += contribution.amountScaled
            updatedAt = .now
            return contribution
        }
    }

    @Model
    final class GoalContribution {
        var id: UUID = UUID()
        /// Positive for a deposit, negative for a withdrawal.
        var amountScaled: Int = 0
        var date: Date = Date.now
        var note: String = ""
        var goal: SavingsGoal?

        init(id: UUID = UUID(), amount: Decimal, date: Date = .now, note: String = "") {
            self.id = id
            self.amountScaled = Money.scaled(amount)
            self.date = date
            self.note = note
        }

        var amount: Decimal {
            get { Money.decimal(fromScaled: amountScaled) }
            set { amountScaled = Money.scaled(newValue) }
        }
    }

    // MARK: - Settings

    /// App-wide settings. There is exactly one row (enforced at app level by `StoreIntegrity`).
    @Model
    final class AppSettings {
        var id: UUID = UUID()
        /// ISO 4217 code used to format amounts. Defaults to the device region's currency.
        var currencyCode: String = "USD"
        /// `Calendar` weekday numbering: 1 = Sunday … 7 = Saturday. Defaults to the device's.
        var firstWeekday: Int = 1
        var hasCompletedOnboarding: Bool = false
        var createdAt: Date = Date.now
        var updatedAt: Date = Date.now

        init(
            id: UUID = UUID(),
            currencyCode: String,
            firstWeekday: Int,
            hasCompletedOnboarding: Bool = false,
            createdAt: Date = .now,
            updatedAt: Date = .now
        ) {
            self.id = id
            self.currencyCode = AppSettings.normalizedCurrencyCode(currencyCode)
            self.firstWeekday = AppSettings.normalizedWeekday(firstWeekday)
            self.hasCompletedOnboarding = hasCompletedOnboarding
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// Settings seeded from the device: region currency and calendar week start.
        static func makeDefault(locale: Locale = .current, calendar: Calendar = .current) -> AppSettings {
            AppSettings(
                currencyCode: locale.currency?.identifier ?? "USD",
                firstWeekday: calendar.firstWeekday
            )
        }

        static func normalizedCurrencyCode(_ code: String) -> String {
            let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return trimmed.count == 3 && trimmed.allSatisfy(\.isLetter) ? trimmed : "USD"
        }

        static func normalizedWeekday(_ weekday: Int) -> Int {
            (1...7).contains(weekday) ? weekday : 1
        }

        /// `base` with the user's chosen first weekday applied.
        func calendar(basedOn base: Calendar = .current) -> Calendar {
            var calendar = base
            calendar.firstWeekday = AppSettings.normalizedWeekday(firstWeekday)
            return calendar
        }
    }
}
