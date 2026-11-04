import Foundation

/// A deterministic, explainable finding produced by `InsightEngine`.
///
/// Every number on an insight is computed from the user's own ledger, never generated: the
/// `evidence` lists the figures behind the headline, and `impactAmount` is the money at stake.
/// What `impactAmount` means depends on `kind` (see each case).
struct Insight: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// Spending already exceeds the category budget. Impact: amount over the limit.
        case budgetBreach
        /// Run rate × days left lands above the budget. Impact: projected amount over the limit.
        case projectedOverrun
        /// A category moved notably against the comparison period. Impact: absolute change.
        case categoryChange
        /// A category total is an outlier against its own history. Impact: excess over the median.
        case categoryAnomaly
        /// A single charge is an outlier for its merchant. Impact: excess over the usual charge.
        case merchantAnomaly
        /// Auto-detected recurring charges. Impact: their combined monthly cost.
        case recurringCharges
        /// A fixed recurring charge went up. Impact: the extra cost per year.
        case priceCreep
        /// Share of income kept last month. Impact: the gap to the target rate, or the amount saved.
        case savingsRate
        /// How many months the reserve covers. Impact: the gap to the next milestone, or the reserve.
        case emergencyRunway
        /// Consecutive days without spending. Impact: estimated spending avoided.
        case noSpendStreak

        /// What the big number on a card means, unless the insight gives its own caption.
        var impactCaption: String {
            switch self {
            case .budgetBreach: "over budget"
            case .projectedOverrun: "projected over budget"
            case .categoryChange: "change against the comparison period"
            case .categoryAnomaly: "above a typical month"
            case .merchantAnomaly: "above the usual charge"
            case .recurringCharges: "per month in recurring charges"
            case .priceCreep: "extra per year"
            case .savingsRate: "savings gap or amount saved"
            case .emergencyRunway: "to the next emergency-fund milestone"
            case .noSpendStreak: "estimated spending avoided"
            }
        }

        var systemImage: String {
            switch self {
            case .budgetBreach: "xmark.octagon.fill"
            case .projectedOverrun: "gauge.with.dots.needle.67percent"
            case .categoryChange: "arrow.up.arrow.down"
            case .categoryAnomaly, .merchantAnomaly: "waveform.path.ecg"
            case .recurringCharges: "repeat"
            case .priceCreep: "arrow.up.right.circle.fill"
            case .savingsRate: "percent"
            case .emergencyRunway: "lifepreserver.fill"
            case .noSpendStreak: "flame.fill"
            }
        }
    }

    enum Severity: Int, Comparable, Sendable {
        case info = 0
        case notice
        case warning
        case critical

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .info: "Info"
            case .notice: "Notice"
            case .warning: "Warning"
            case .critical: "Critical"
            }
        }

        /// The name shown in the interface, in the person's language. `title` stays English because
        /// it feeds insight text, AI prompts and exports.
        var localizedTitle: String {
            switch self {
            case .info: String(localized: "Info")
            case .notice: String(localized: "Notice")
            case .warning: String(localized: "Warning")
            case .critical: String(localized: "Critical")
            }
        }
    }

    /// One figure supporting an insight. Values stay typed so the UI formats them for the locale
    /// and currency instead of the engine baking strings in.
    struct Evidence: Equatable, Sendable {
        enum Value: Equatable, Sendable {
            case money(Decimal)
            /// A fraction, so `0.25` is 25%.
            case percent(Double)
            case count(Int)
            case days(Int)
            case months(Double)
            case number(Double)
            case date(Date)
            case text(String)
        }

        let label: String
        let value: Value

        init(_ label: String, _ value: Value) {
            self.label = label
            self.value = value
        }
    }

    /// Stable across recomputations of the same finding in the same period, so dismissals and
    /// snoozes keep matching. A new period yields a new id and the finding can surface again.
    let id: String
    let kind: Kind
    let severity: Severity
    let title: String
    let summary: String
    let impactAmount: Decimal
    /// What `impactAmount` means for this particular insight.
    let impactCaption: String
    let evidence: [Evidence]
    let suggestedAction: String
    let category: SpendingCategory?
    let merchant: String?

    init(
        id: String,
        kind: Kind,
        severity: Severity,
        title: String,
        summary: String,
        impactAmount: Decimal,
        impactCaption: String? = nil,
        evidence: [Evidence],
        suggestedAction: String,
        category: SpendingCategory? = nil,
        merchant: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.title = title
        self.summary = summary
        self.impactAmount = impactAmount
        self.impactCaption = impactCaption ?? kind.impactCaption
        self.evidence = evidence
        self.suggestedAction = suggestedAction
        self.category = category
        self.merchant = merchant
    }
}

/// How often a detected recurring charge repeats.
enum RecurringCadence: String, CaseIterable, Sendable {
    case weekly
    case biweekly
    case monthly
    case quarterly

    var title: String {
        switch self {
        case .weekly: "weekly"
        case .biweekly: "every 2 weeks"
        case .monthly: "monthly"
        case .quarterly: "quarterly"
        }
    }

    /// Nominal days between charges.
    var nominalDays: Int {
        switch self {
        case .weekly: 7
        case .biweekly: 14
        case .monthly: 30
        case .quarterly: 91
        }
    }

    /// Range a single gap may fall in and still count as this cadence (months vary from 28 to 31
    /// days and charges slip over weekends).
    var gapRange: ClosedRange<Int> {
        switch self {
        case .weekly: 5...9
        case .biweekly: 11...17
        case .monthly: 26...35
        case .quarterly: 80...102
        }
    }

    /// Range the *median* gap must fall in to be classified as this cadence.
    var medianRange: ClosedRange<Int> {
        switch self {
        case .weekly: 6...8
        case .biweekly: 12...16
        case .monthly: 28...33
        case .quarterly: 85...97
        }
    }

    var chargesPerYear: Int {
        switch self {
        case .weekly: 52
        case .biweekly: 26
        case .monthly: 12
        case .quarterly: 4
        }
    }

    /// Cost spread evenly over a month.
    func monthlyEquivalent(of amount: Decimal) -> Decimal {
        amount * Decimal(chargesPerYear) / 12
    }
}

/// A recurring charge found by `RecurringChargeDetector` from merchant + amount + cadence.
struct DetectedRecurringCharge: Identifiable, Equatable, Sendable {
    let key: String
    let merchant: String
    let category: SpendingCategory
    let cadence: RecurringCadence
    let occurrences: Int
    /// Median charge at the current price for a fixed-price charge, otherwise across the history.
    let typicalAmount: Decimal
    let latestAmount: Decimal
    /// The charge immediately before the latest one.
    let previousAmount: Decimal
    let firstDate: Date
    let lastDate: Date
    let nextExpectedDate: Date?
    /// True when the charges are within 2% of each other before and after the latest price step (a
    /// subscription rather than a variable bill).
    let isFixedAmount: Bool

    var id: String { key }
    var monthlyEquivalent: Decimal { cadence.monthlyEquivalent(of: latestAmount) }
}
