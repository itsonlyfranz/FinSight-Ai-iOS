import Foundation
import os

enum CurrencyFormatter {
    /// The currency the user picked in Settings. `nil` means "follow the device region".
    private static let selectedCode = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Applies (or, with `nil`, clears) the currency chosen in Settings for every default-argument call.
    static func setSelectedCurrencyCode(_ code: String?) {
        let normalized = code.map(AppSettings.normalizedCurrencyCode)
        selectedCode.withLock { $0 = normalized }
    }

    /// ISO 4217 code for the device region (falls back to USD when the locale has no currency).
    static func currencyCode(for locale: Locale = .current) -> String {
        locale.currency?.identifier ?? "USD"
    }

    /// The code amounts are shown in: the Settings choice, else the device region's currency.
    static var currencyCode: String {
        selectedCode.withLock { $0 } ?? currencyCode(for: .current)
    }

    /// With no `locale`, uses the selected currency; with one, that locale's own currency.
    static func string(from value: Double, locale: Locale? = nil) -> String {
        let resolved = locale ?? .current
        return value.formatted(.currency(code: locale == nil ? currencyCode : currencyCode(for: resolved)).locale(resolved))
    }

    static func string(from value: Decimal, currencyCode: String? = nil, locale: Locale? = nil) -> String {
        let resolved = locale ?? .current
        let code = currencyCode ?? (locale == nil ? self.currencyCode : self.currencyCode(for: resolved))
        return value.formatted(.currency(code: code).locale(resolved))
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
        formatter.setLocalizedDateFormatFromTemplate("LLLLyyyy")
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
