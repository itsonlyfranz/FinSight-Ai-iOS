import Foundation

/// Small robust-statistics helpers. Money stays `Decimal`; only the dimensionless z-score is a `Double`.
enum InsightStatistics {
    /// Scale factor that makes MAD a consistent estimator of the standard deviation for normal data.
    static let madConsistency = 1.4826
    /// Same, for the mean absolute deviation (used when MAD collapses to zero).
    static let meanAbsoluteDeviationConsistency = 1.2533

    static func median(_ values: [Decimal]) -> Decimal {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// Median absolute deviation around `center` (the median by default).
    static func mad(_ values: [Decimal], around center: Decimal? = nil) -> Decimal {
        guard !values.isEmpty else { return 0 }
        let pivot = center ?? median(values)
        return median(values.map { abs($0 - pivot) })
    }

    static func meanAbsoluteDeviation(_ values: [Decimal], around center: Decimal) -> Decimal {
        guard !values.isEmpty else { return 0 }
        return values.map { abs($0 - center) }.sum() / Decimal(values.count)
    }

    struct Baseline: Equatable, Sendable {
        let median: Decimal
        let mad: Decimal
        /// Robust standard-deviation estimate, floored so perfectly regular history cannot make
        /// every deviation look infinite.
        let scale: Decimal
        let sampleCount: Int

        /// Robust z-score of `value`: how many robust standard deviations above (+) or below (−) the median.
        func zScore(of value: Decimal) -> Double {
            guard scale > 0 else { return 0 }
            return ((value - median) / scale).doubleValue
        }
    }

    /// Median/MAD baseline.
    /// - Parameters:
    ///   - relativeFloor: minimum scale as a share of the median (10% by default).
    ///   - absoluteFloor: minimum scale in currency units, for baselines whose median is zero.
    static func baseline(
        of values: [Decimal],
        relativeFloor: Decimal = Decimal(string: "0.1")!,
        absoluteFloor: Decimal = 0
    ) -> Baseline {
        let center = median(values)
        let deviation = mad(values, around: center)
        var scale = deviation * Decimal(madConsistency)
        if scale == 0 {
            scale = meanAbsoluteDeviation(values, around: center) * Decimal(meanAbsoluteDeviationConsistency)
        }
        scale = max(scale, center * relativeFloor, absoluteFloor)
        return Baseline(median: center, mad: deviation, scale: scale, sampleCount: values.count)
    }
}

/// Lowercased, punctuation-free merchant identity so "NETFLIX.COM", "Netflix" and "netflix #123"
/// group together.
enum MerchantNormalizer {
    static func key(for name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var words: [String] = []
        var current = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        // Drop bare domain suffixes so "netflix.com" matches "netflix".
        let suffixes: Set<String> = ["com", "net", "org", "ph", "co", "inc", "ltd", "llc"]
        let kept = words.filter { !suffixes.contains($0) }
        return (kept.isEmpty ? words : kept).joined(separator: " ")
    }
}
