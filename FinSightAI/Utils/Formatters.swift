import Foundation

enum CurrencyFormatter {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "PHP"
        formatter.currencySymbol = "₱"
        formatter.locale = Locale(identifier: "en_PH")
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter
    }()

    private static let plainFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter
    }()

    static func pesoString(from value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "₱0.00"
    }

    static func plainNumberString(from value: Double) -> String {
        plainFormatter.string(from: NSNumber(value: value)) ?? "0"
    }
}

enum PercentFormatter {
    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    static func string(from value: Double) -> String {
        formatter.string(from: NSNumber(value: value)) ?? "0%"
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
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func updatedString(for date: Date) -> String {
        "Updated \(formatter.localizedString(for: date, relativeTo: .now))"
    }
}
