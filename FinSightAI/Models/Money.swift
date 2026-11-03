import Foundation

/// Exact money handling at the persistence boundary.
///
/// SwiftData/Core Data store `Decimal` as a floating-point column, which silently loses exactness,
/// so money is persisted as an `Int` count of 1/10,000 currency units (`Money.scale` = 4 fractional
/// digits, enough for every ISO 4217 currency) and exposed to the app as `Decimal`. The scale is
/// fixed and independent of the selected currency, so changing the currency setting never
/// reinterprets stored amounts.
enum Money {
    /// Number of fractional digits kept in storage.
    static let scale = 4
    private static let factor = Decimal(10_000)
    /// Largest magnitude (in whole currency units) that can be stored: far beyond any real balance,
    /// but small enough that `Int` conversion can never overflow.
    static let maximumMagnitude = Decimal(900_000_000_000_000)

    /// Rounds to the storage scale using conventional ("round half away from zero") rounding.
    static func rounded(_ value: Decimal) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, scale, .plain)
        return output
    }

    /// Persisted representation of `value`. Non-finite values store as 0; out-of-range values clamp.
    static func scaled(_ value: Decimal) -> Int {
        guard !value.isNaN else { return 0 }
        let clamped = min(max(value, -maximumMagnitude), maximumMagnitude)
        var scaledValue = clamped * factor
        var whole = Decimal()
        NSDecimalRound(&whole, &scaledValue, 0, .plain)
        return NSDecimalNumber(decimal: whole).intValue
    }

    static func decimal(fromScaled scaled: Int) -> Decimal {
        Decimal(scaled) / factor
    }

    /// Converts a legacy `Double` amount using its shortest decimal representation, so `0.1` migrates
    /// to exactly 0.1 rather than to the binary approximation 0.1000000000000000055….
    static func decimal(fromLegacy value: Double) -> Decimal {
        guard value.isFinite else { return 0 }
        return Decimal(string: "\(value)", locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(value)
    }

    static func scaled(fromLegacy value: Double) -> Int {
        scaled(decimal(fromLegacy: value))
    }
}

extension Decimal {
    /// Lossy conversion for presentation (charts, formatting). Never use it to accumulate money.
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

extension Sequence where Element == Decimal {
    func sum() -> Decimal {
        reduce(0, +)
    }
}
