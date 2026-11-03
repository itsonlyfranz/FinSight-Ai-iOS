import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// RFC 4180 CSV: comma-separated fields, CRLF record separators, and double-quote quoting.
enum CSV {
    /// A field is quoted when it contains a comma, double quote, CR or LF — or, so that surrounding
    /// whitespace survives a round trip, begins or ends with a space or tab. Embedded quotes double.
    static func escape(_ field: String) -> String {
        // Scalars, not Characters: "\r\n" is a single Character in Swift and would not equal "\r" or "\n".
        let needsQuotes = field.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }
            || field.first.map { $0 == " " || $0 == "\t" } == true
            || field.last.map { $0 == " " || $0 == "\t" } == true
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    static func document(header: [String], rows: [[String]]) -> String {
        ([header] + rows).map(line).joined(separator: "\r\n") + "\r\n"
    }

    /// Parses RFC 4180 text into records of fields. Accepts CRLF, LF or CR record separators and a
    /// missing trailing newline. Returns nil for malformed input (an unterminated quote, or text
    /// after a closing quote).
    static func parse(_ text: String) -> [[String]]? {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var justClosedQuote = false
        var fieldStarted = false
        let scalars = Array(text.unicodeScalars)
        var index = 0

        func endField() {
            record.append(field)
            field = ""
            fieldStarted = false
            justClosedQuote = false
        }
        func endRecord() {
            endField()
            records.append(record)
            record = []
        }

        while index < scalars.count {
            let scalar = scalars[index]
            if inQuotes {
                if scalar == "\"" {
                    if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        index += 1
                    } else {
                        inQuotes = false
                        justClosedQuote = true
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else {
                switch scalar {
                case "\"":
                    guard !fieldStarted, !justClosedQuote else { return nil }
                    inQuotes = true
                    fieldStarted = true
                case ",":
                    endField()
                case "\r", "\n":
                    if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                    endRecord()
                default:
                    guard !justClosedQuote else { return nil }
                    field.unicodeScalars.append(scalar)
                    fieldStarted = true
                }
            }
            index += 1
        }
        if inQuotes { return nil }
        if fieldStarted || justClosedQuote || !record.isEmpty { endRecord() }
        return records
    }
}

/// An immutable, `Sendable` copy of the fields a CSV row needs.
struct TransactionExportRow: Equatable, Sendable {
    let date: Date
    let kind: TransactionKind
    let merchant: String
    let category: SpendingCategory
    let amount: Decimal
    let note: String

    init(_ record: TransactionRecord) {
        date = record.date
        kind = record.kind
        merchant = record.merchantName
        category = record.category
        amount = record.amount
        note = record.note
    }
}

enum TransactionCSVExporter {
    static let header = ["Date", "Type", "Merchant", "Category", "Amount", "Note"]

    /// `yyyy-MM-dd` in the supplied calendar's time zone.
    static func dateString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Amounts use "." as the decimal separator and no grouping, whatever the device locale, so
    /// the file reads the same everywhere. Amounts are non-negative; `Type` carries the direction.
    static func amountString(_ amount: Decimal) -> String {
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, Money.scale, .plain)
        var text = NSDecimalNumber(decimal: rounded).description(withLocale: Locale(identifier: "en_US_POSIX"))
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text
    }

    static func csv(rows: [TransactionExportRow], calendar: Calendar = .current) -> String {
        let sorted = rows.sorted { $0.date > $1.date }
        return CSV.document(
            header: header,
            rows: sorted.map { row in
                [
                    dateString(row.date, calendar: calendar),
                    row.kind.rawValue,
                    row.merchant,
                    row.category.rawValue,
                    amountString(row.amount),
                    row.note
                ]
            }
        )
    }

    static func fileName(now: Date = .now, calendar: Calendar = .current) -> String {
        "FinSight-transactions-\(dateString(now, calendar: calendar)).csv"
    }
}

/// Shareable CSV of the ledger. The file is written only when the user actually shares it.
struct TransactionsCSVExport: Transferable, Sendable {
    let rows: [TransactionExportRow]
    let fileName: String

    init(transactions: [TransactionRecord], now: Date = .now) {
        rows = transactions.map(TransactionExportRow.init)
        fileName = TransactionCSVExporter.fileName(now: now)
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(export.fileName)
            try TransactionCSVExporter.csv(rows: export.rows).write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
