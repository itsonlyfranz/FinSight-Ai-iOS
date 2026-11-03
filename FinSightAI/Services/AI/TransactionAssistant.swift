import Foundation

/// Smart help while adding a transaction: pick a category, read a sentence. Behind a protocol so the
/// app runs the on-device model in production and tests run a deterministic stand-in.
protocol TransactionAssistant: Sendable {
    var providerIdentifier: String { get }
    /// Loads the model ahead of first use. Safe to call repeatedly.
    func prewarm()
    /// A category for a new transaction, from its merchant and note, or `nil` when nothing fits.
    func suggestCategory(merchant: String, note: String) async -> CategorySuggestion?
    /// Reads "coffee 150 yesterday" into a draft's fields.
    func parseQuickAdd(_ text: String, now: Date, calendar: Calendar, locale: Locale) async -> QuickAddResult
}

extension TransactionAssistant {
    func prewarm() {}
}

/// Rules only: keyword categories and the code parser. What runs when the model isn't available,
/// and what the model-backed assistant starts from.
struct RuleBasedTransactionAssistant: TransactionAssistant {
    let providerIdentifier = "rules"

    func suggestCategory(merchant: String, note: String) async -> CategorySuggestion? {
        KeywordCategorizer.suggestion(merchant: merchant, note: note)
    }

    func parseQuickAdd(_ text: String, now: Date, calendar: Calendar, locale: Locale) async -> QuickAddResult {
        QuickAddParser.parse(text, now: now, calendar: calendar, locale: locale)
    }
}

/// What the model may change about a quick-add sentence: wording and classification, never numbers.
struct QuickAddInterpretation: Equatable, Sendable {
    var merchant: String
    var kind: TransactionKind
    var category: SpendingCategory?
}

extension QuickAddResult {
    /// Applies the model's reading on top of the code-parsed result. The amount and date stay as
    /// parsed; an empty or missing field keeps the parsed value. A kind or category the code read
    /// from the user's words wins: the model only fills in what the rules left at their defaults.
    func merging(_ interpretation: QuickAddInterpretation) -> QuickAddResult {
        var merged = self
        let merchant = MerchantNameCleaner.clean(interpretation.merchant)
        if !merchant.isEmpty { merged.merchant = merchant }
        if kind == .expense { merged.kind = interpretation.kind }
        switch merged.kind {
        case .income:
            merged.category = nil
        case .expense:
            merged.category = category ?? interpretation.category.map { CategorySuggestion(category: $0, source: .model) }
        case .transfer:
            break
        }
        return merged
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// The categories the model may choose from. Mirrors `SpendingCategory` minus `savings`: money set
/// aside is not something an expense is categorised as.
@Generable(description: "A spending category.")
enum SpendingCategoryChoice: String, CaseIterable {
    case groceries
    case dining
    case transport
    case bills
    case shopping
    case health
    case entertainment
    case travel
    case other

    var category: SpendingCategory {
        // The raw values are shared with `SpendingCategory`; the fallback is unreachable but safe.
        SpendingCategory(rawValue: rawValue) ?? .other
    }
}

@Generable(description: "Whether money came in or went out.")
enum TransactionKindChoice: String, CaseIterable {
    case expense
    case income

    var kind: TransactionKind { self == .income ? .income : .expense }
}

@Generable(description: "A category chosen for one transaction.")
struct CategoryPick {
    @Guide(description: "The best-fitting category for this merchant and note. Use other if unsure.")
    var category: SpendingCategoryChoice
}

@Generable(description: "A short money note read into fields.")
struct QuickAddReading {
    @Guide(description: "The merchant or income source as a person would write it, e.g. 'Starbucks'. Use only words from the note; never invent a name. No amounts or dates.")
    var merchant: String
    @Guide(description: "income only for pay, salary or money received; otherwise expense.")
    var kind: TransactionKindChoice
    @Guide(description: "The best-fitting category when it is an expense. Use other if unsure.")
    var category: SpendingCategoryChoice
}

/// Rules first, the on-device model second: a keyword hit is instant and never wrong-footed by the
/// model, and the model handles what the rules don't recognise.
struct FoundationModelsTransactionAssistant: TransactionAssistant {
    let providerIdentifier = "apple-foundation-models"
    private let capabilityService: CapabilityService
    private let rules = RuleBasedTransactionAssistant()

    init(capabilityService: CapabilityService = DefaultCapabilityService()) {
        self.capabilityService = capabilityService
    }

    private var isAvailable: Bool { capabilityService.aiAvailability.isAvailable }

    func prewarm() {
        guard isAvailable else { return }
        LanguageModelSession(instructions: Self.instructions).prewarm()
    }

    func suggestCategory(merchant: String, note: String) async -> CategorySuggestion? {
        if let byRule = await rules.suggestCategory(merchant: merchant, note: note) { return byRule }
        let name = MerchantNameCleaner.clean(merchant)
        guard isAvailable, !name.isEmpty else { return nil }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = "Merchant: \(name)" + (note.isEmpty ? "" : "\nNote: \(note)")
            let pick = try await session.respond(to: prompt, generating: CategoryPick.self).content
            return CategorySuggestion(category: pick.category.category, source: .model)
        } catch {
            return nil
        }
    }

    func parseQuickAdd(_ text: String, now: Date, calendar: Calendar, locale: Locale) async -> QuickAddResult {
        let parsed = QuickAddParser.parse(text, now: now, calendar: calendar, locale: locale)
        guard isAvailable, !parsed.remainder.isEmpty else { return parsed }
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let reading = try await session.respond(to: "Note: \(parsed.remainder)", generating: QuickAddReading.self).content
            return parsed.merging(
                QuickAddInterpretation(merchant: reading.merchant, kind: reading.kind.kind, category: reading.category.category)
            )
        } catch {
            return parsed
        }
    }

    private static let instructions = """
        You file personal finance transactions. Given a short note or merchant name, pick the category \
        and clean up the merchant name. Never output amounts or dates.
        """
}
#endif
