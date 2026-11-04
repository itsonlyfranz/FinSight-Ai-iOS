#if canImport(FoundationModels)
import Foundation
import FoundationModels

/// The tools Ask FinSight's model can call: the Phase 4 ledger tools plus month review and
/// affordability. Each one runs through `AssistantToolbox`, so every number comes from code.
enum AssistantTools {
    static func all(for toolbox: AssistantToolbox) -> [any Tool] {
        LedgerTools.all(for: toolbox.context.ledger, log: toolbox.log) + [
            MonthReviewTool(toolbox: toolbox),
            AffordabilityTool(toolbox: toolbox)
        ]
    }
}

struct MonthReviewTool: Tool {
    let toolbox: AssistantToolbox
    let name = "monthReview"
    var description: String {
        "Compares one month's spending with the month before it: totals, the categories that changed most and the largest purchases. "
            + "The current month is \(LedgerText.monthLabel(toolbox.context.ledger, monthsAgo: 0)). Use it for questions like 'Why was March so high?'."
    }

    @Generable
    struct Arguments {
        @Guide(description: "Months before the current month: 0 is the current month, 1 is the month before it, and so on up to 11.", .range(0...11))
        var monthsAgo: Int
    }

    func call(arguments: Arguments) async throws -> String {
        toolbox.run(.monthReview(monthsAgo: arguments.monthsAgo))
    }
}

struct AffordabilityTool: Tool {
    let toolbox: AssistantToolbox
    let name = "affordability"
    let description = "Checks whether an amount fits in what is left of this month's income after spending so far and the recurring charges still due."

    @Generable
    struct Arguments {
        @Guide(description: "The amount the user asked about, as a plain number. '8k' is 8000.")
        var amount: Double
    }

    func call(arguments: Arguments) async throws -> String {
        let amount = Decimal(string: String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), max(0, arguments.amount)), locale: Locale(identifier: "en_US_POSIX")) ?? 0
        return toolbox.run(.affordability(amount: amount))
    }
}

/// Answers with Apple's on-device model, streaming the text and mapping the OS's errors (which
/// differ between the iOS 26 and iOS 27 SDKs) to `AssistantEngineError`.
struct FoundationModelsAssistantEngine: AssistantEngine {
    var contextSize: Int { SystemLanguageModel.default.contextSize }

    func prewarm(instructions: String) {
        LanguageModelSession(instructions: instructions).prewarm()
    }

    func respond(
        instructions: String,
        prompt: String,
        toolbox: AssistantToolbox?,
        onPartial: (@Sendable (String) async -> Void)?
    ) async throws -> String {
        let tools = toolbox.map(AssistantTools.all(for:)) ?? []
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        do {
            var latest = ""
            for try await snapshot in session.streamResponse(to: prompt) {
                latest = snapshot.content
                await onPartial?(latest)
            }
            return latest
        } catch let error as CancellationError {
            throw error
        } catch {
            throw Self.engineError(for: error)
        }
    }

    @available(iOS, introduced: 26.0, deprecated: 27.0)
    @available(macOS, introduced: 26.0, deprecated: 27.0)
    static func engineError(for error: Error) -> AssistantEngineError {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .refusal: return .refusal
            case .guardrailViolation: return .guardrailViolation
            case .exceededContextWindowSize: return .contextOverflow
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            default: return .failed
            }
        }
        // LanguageModelError only exists in the iOS 27 SDK (Swift 6.4 toolchain); CI builds with the iOS 26 SDK.
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 27.0, *), let modern = error as? LanguageModelError {
            switch modern {
            case .refusal: return .refusal
            case .guardrailViolation: return .guardrailViolation
            case .contextSizeExceeded: return .contextOverflow
            case .unsupportedLanguageOrLocale: return .unsupportedLanguage
            default: return .failed
            }
        }
        #endif
        return .failed
    }
}
#endif
