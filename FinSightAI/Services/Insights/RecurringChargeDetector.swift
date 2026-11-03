import Foundation

/// Finds recurring charges and subscriptions from repeated merchant + amount + cadence.
struct RecurringChargeDetector: Sendable {
    let configuration: InsightEngineConfiguration

    init(configuration: InsightEngineConfiguration = InsightEngineConfiguration()) {
        self.configuration = configuration
    }

    /// - Parameter entries: any transactions; only spending is considered. Entries after today are ignored.
    func detect(in entries: [LedgerEntry], now: Date, calendar: Calendar) -> [DetectedRecurringCharge] {
        let today = calendar.startOfDay(for: now)
        let spending = entries.filter { $0.countsAsSpending && calendar.startOfDay(for: $0.date) <= today }
        let groups = Dictionary(grouping: spending) { MerchantNormalizer.key(for: $0.merchant) }

        return groups.compactMap { key, group -> DetectedRecurringCharge? in
            guard !key.isEmpty else { return nil }
            return charge(for: key, entries: group, today: today, calendar: calendar)
        }
        .sorted { lhs, rhs in
            if lhs.monthlyEquivalent != rhs.monthlyEquivalent { return lhs.monthlyEquivalent > rhs.monthlyEquivalent }
            return lhs.key < rhs.key
        }
    }

    private func charge(
        for key: String,
        entries: [LedgerEntry],
        today: Date,
        calendar: Calendar
    ) -> DetectedRecurringCharge? {
        // One charge per day: a duplicate posting on the same day is not a second occurrence.
        var seenDays = Set<Date>()
        let series = entries
            .sorted { ($0.date, $0.id.uuidString) < ($1.date, $1.id.uuidString) }
            .filter { seenDays.insert(calendar.startOfDay(for: $0.date)).inserted }
        guard series.count >= configuration.recurringMinimumOccurrences,
              let first = series.first, let last = series.last else { return nil }

        let gaps = zip(series, series.dropFirst()).map { Self.days(from: $0.date, to: $1.date, calendar: calendar) }
        guard let cadence = cadence(forGaps: gaps) else { return nil }

        let sinceLast = Self.days(from: last.date, to: today, calendar: calendar)
        guard Double(sinceLast) <= Double(cadence.nominalDays) * configuration.recurringActiveCadenceMultiple else {
            return nil
        }

        let amounts = series.map(\.amount)
        let latest = amounts[amounts.count - 1]
        let median = InsightStatistics.median(amounts)
        let steadyBill = Self.allWithin(amounts, of: median, tolerance: configuration.recurringAmountTolerance)
        // A fixed-price subscription may jump by more than the tolerance at each price step (a price
        // hike): every earlier price must have held for at least two charges.
        let prices = Self.priceStretches(of: amounts)
        let current = prices[prices.count - 1]
        let previousMedian = prices.count >= 2 ? InsightStatistics.median(prices[prices.count - 2]) : latest
        let isFixedAmount = prices.dropLast().allSatisfy { $0.count >= 2 }
            && latest >= previousMedian / 2 && latest <= previousMedian * 2
        guard median > 0, steadyBill || isFixedAmount else { return nil }

        return DetectedRecurringCharge(
            key: key,
            merchant: last.merchant.trimmingCharacters(in: .whitespacesAndNewlines),
            category: last.category,
            cadence: cadence,
            occurrences: series.count,
            typicalAmount: isFixedAmount ? InsightStatistics.median(current) : median,
            latestAmount: latest,
            previousAmount: amounts[amounts.count - 2],
            firstDate: first.date,
            lastDate: last.date,
            nextExpectedDate: Self.nextDate(after: last.date, cadence: cadence, calendar: calendar),
            isFixedAmount: isFixedAmount
        )
    }

    private func cadence(forGaps gaps: [Int]) -> RecurringCadence? {
        guard !gaps.isEmpty else { return nil }
        let sorted = gaps.sorted()
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
        guard let cadence = RecurringCadence.allCases.first(where: { $0.medianRange.contains(median) }) else { return nil }
        let agreeing = gaps.filter { cadence.gapRange.contains($0) }.count
        return Double(agreeing) / Double(gaps.count) >= configuration.recurringGapAgreement ? cadence : nil
    }

    /// Tolerance for "the same price".
    static let fixedTolerance = Decimal(string: "0.02")!

    /// Splits the amounts, oldest first, into runs at one price: each run is within `fixedTolerance`
    /// of its own last amount.
    static func priceStretches(of amounts: [Decimal]) -> [[Decimal]] {
        var remaining = amounts[...]
        var stretches: [[Decimal]] = []
        while let last = remaining.last {
            let count = remaining.reversed().prefix { abs($0 - last) <= last * fixedTolerance }.count
            stretches.insert(Array(remaining.suffix(count)), at: 0)
            remaining = remaining.dropLast(count)
        }
        return stretches
    }

    static func allWithin(_ values: [Decimal], of center: Decimal, tolerance: Decimal) -> Bool {
        let allowed = center * tolerance
        return values.allSatisfy { abs($0 - center) <= allowed }
    }

    /// Whole calendar days from `start` to `end`, counted on local day boundaries so a DST change
    /// never makes a day 23 or 25 hours long.
    static func days(from start: Date, to end: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: end)).day ?? 0
    }

    static func nextDate(after date: Date, cadence: RecurringCadence, calendar: Calendar) -> Date? {
        switch cadence {
        case .weekly: calendar.date(byAdding: .day, value: 7, to: date)
        case .biweekly: calendar.date(byAdding: .day, value: 14, to: date)
        case .monthly: calendar.date(byAdding: .month, value: 1, to: date)
        case .quarterly: calendar.date(byAdding: .month, value: 3, to: date)
        }
    }
}
