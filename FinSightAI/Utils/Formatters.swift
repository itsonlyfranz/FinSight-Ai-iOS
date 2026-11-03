import Foundation

enum CurrencyFormatter {
    /// ISO 4217 code for the device region (falls back to USD when the locale has no currency).
    static func currencyCode(for locale: Locale = .current) -> String {
        locale.currency?.identifier ?? "USD"
    }

    static var currencyCode: String { currencyCode() }

    static func string(from value: Double, locale: Locale = .current) -> String {
        value.formatted(.currency(code: currencyCode(for: locale)).locale(locale))
    }

    static func string(from value: Decimal, currencyCode: String? = nil, locale: Locale = .current) -> String {
        value.formatted(.currency(code: currencyCode ?? self.currencyCode(for: locale)).locale(locale))
    }

    /// Editable representation of an amount: no grouping, locale decimal separator.
    static func plainNumberString(from value: Decimal, locale: Locale = .current) -> String {
        value.formatted(
            .number
                .locale(locale)
                .grouping(.never)
                .precision(.fractionLength(0...Money.scale))
        )
    }

    static func plainNumberString(from value: Double, locale: Locale = .current) -> String {
        value.formatted(
            .number
                .locale(locale)
                .grouping(.never)
                .precision(.fractionLength(0...2))
        )
    }
}

/// Parses user-typed amounts using the rules of a locale, so `12,50` is 12.5 in a
/// comma-decimal locale and `1,250.50` is 1250.5 in en_US.
enum AmountParser {
    static func parse(_ text: String, locale: Locale = .current) -> Decimal? {
        let trimmed = text.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
            .map(String.init)
            .joined()
        guard !trimmed.isEmpty else { return nil }

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.isLenient = false
        formatter.generatesDecimalNumbers = true
        guard let number = formatter.number(from: trimmed) as? NSDecimalNumber else { return nil }

        let value = number.decimalValue
        return value.isNaN ? nil : value
    }
}

enum PercentFormatter {
    static func string(from value: Double, locale: Locale = .current) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}

enum MonthFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private static let sectionFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    static func label(for date: Date) -> String {
        formatter.string(from: date)
    }

    static func sectionID(for date: Date) -> String {
        sectionFormatter.string(from: date)
    }
}

enum DayFormatter {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dayKey(for date: Date) -> String {
        formatter.string(from: date)
    }
}

enum RelativeTimestampFormatter {
    static func updatedString(for date: Date) -> String {
        let relative = date.formatted(.relative(presentation: .numeric, unitsStyle: .wide).locale(.current))
        return "Updated \(relative)"
    }
}
