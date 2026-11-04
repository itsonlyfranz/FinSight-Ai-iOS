import XCTest
@testable import FinSightAI

/// The String Catalog ships English source strings with a Filipino (`fil`) translation for each.
final class LocalizationTests: XCTestCase {
    /// Proper nouns and brand names that read the same in Filipino.
    private static let sameInFilipino: Set<String> = [
        "Deck Emerald", "Cyber Slate", "Midnight Blue", "Emerald", "Cyber", "Midnight",
        "Dashboard", "Simulator", "Settings", "Profile", "OK"
    ]

    private struct CatalogEntry {
        let english: String
        let filipino: String?
        let filipinoState: String?
    }

    private func loadCatalog() throws -> [String: CatalogEntry] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("FinSightAI/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")
        let strings = try XCTUnwrap(root["strings"] as? [String: [String: Any]])
        return strings.reduce(into: [:]) { result, item in
            let localizations = item.value["localizations"] as? [String: Any]
            let english = ((localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            let filipinoUnit = (localizations?["fil"] as? [String: Any])?["stringUnit"] as? [String: Any]
            result[item.key] = CatalogEntry(
                english: english ?? item.key,
                filipino: filipinoUnit?["value"] as? String,
                filipinoState: filipinoUnit?["state"] as? String
            )
        }
    }

    /// Format specifiers by type, ignoring positional indexes (`%1$@` counts as `%@`).
    private func specifiers(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(lld|ld|d|@|f|%)")
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
            .sorted()
    }

    func testEveryCatalogKeyHasATranslatedFilipinoString() throws {
        let catalog = try loadCatalog()
        XCTAssertGreaterThan(catalog.count, 300)
        for key in catalog.keys where key.range(of: "\\S", options: .regularExpression) != nil {
            let entry = catalog[key]!
            XCTAssertNotNil(entry.filipino, "Missing Filipino: \(key)")
            XCTAssertEqual(entry.filipinoState, "translated", "Filipino not marked translated: \(key)")
        }
    }

    func testFilipinoKeepsEveryFormatSpecifier() throws {
        for (key, entry) in try loadCatalog() {
            guard let filipino = entry.filipino else { continue }
            XCTAssertEqual(specifiers(filipino), specifiers(entry.english), "Specifiers differ for: \(key)")
        }
    }

    func testFilipinoIsATranslationNotAnEnglishCopy() throws {
        let catalog = try loadCatalog()
        let copies = catalog.filter { key, entry in
            key.replacingOccurrences(of: "%(\\d+\\$)?(lld|ld|d|@|f|%)", with: "", options: .regularExpression)
                .range(of: "[A-Za-z]", options: .regularExpression) != nil
                && entry.filipino == entry.english
                && !Self.sameInFilipino.contains(key)
        }
        XCTAssertTrue(copies.isEmpty, "Untranslated: \(copies.keys.sorted())")
    }

    func testAppBundleShipsFilipino() throws {
        XCTAssertTrue(Bundle.main.localizations.contains("fil"), "\(Bundle.main.localizations)")
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fil", ofType: "lproj"))
        let filipino = try XCTUnwrap(Bundle(path: path))
        for key in ["Start my plan", "Monthly income", "Load sample data", "Theme Options", "This month's outflow"] {
            let value = filipino.localizedString(forKey: key, value: nil, table: nil)
            XCTAssertNotEqual(value, key, "Not localized at runtime: \(key)")
            XCTAssertFalse(value.isEmpty)
        }
    }

    func testEnglishPluralsReadNaturally() {
        XCTAssertEqual(String(localized: "\(1) months to go"), "1 month to go")
        XCTAssertEqual(String(localized: "\(3) months to go"), "3 months to go")
        XCTAssertEqual(String(localized: "\(1) categories"), "1 category")
    }

    func testSpendingTrendIsLocalizedForDisplayButStaysEnglishForTheAIPrompt() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = { (m: Int, d: Int) in utc.date(from: DateComponents(year: 2026, month: m, day: d))! }
        let entries = [
            LedgerEntry(amount: 150, category: .dining, date: date(11, 5)),
            LedgerEntry(amount: 100, category: .dining, date: date(10, 5))
        ]
        let english = "Spending is up 50% compared with the same days last month."
        XCTAssertEqual(SpendingTrend.description(entries: entries, now: date(11, 15), calendar: utc), english)

        var resource = SpendingTrend.resource(entries: entries, now: date(11, 15), calendar: utc)
        resource.locale = Locale(identifier: "fil")
        let filipino = String(localized: resource)
        XCTAssertNotEqual(filipino, english, "trend sentence is not localized")
        XCTAssertTrue(filipino.contains("50%"), filipino)
    }

    func testCategoryNamesAreLocalizedForTheInterfaceButStayEnglishForInsights() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "fil", ofType: "lproj"))
        let filipino = try XCTUnwrap(Bundle(path: path))
        XCTAssertNotEqual(filipino.localizedString(forKey: "Groceries", value: nil, table: nil), "Groceries")
        XCTAssertEqual(SpendingCategory.groceries.title, "Groceries", "insight text and exports keep English names")
    }
}
