import Foundation

/// The assistant's own limits, checked in code before any model sees the question, so they hold on
/// every device and in the quick-answer fallback too.
enum AssistantGuardrails {
    enum Topic: String, Equatable, Sendable {
        /// Picks of specific stocks, funds, crypto or other securities.
        case investmentPicks
        /// Tax filing or legal questions.
        case taxOrLegal
        /// Fraud, laundering, evasion and similar.
        case unlawful
    }

    /// The topic the question falls under if it is outside what FinSight should answer.
    static func screen(_ question: String) -> Topic? {
        let text = AssistantFAQ.normalized(question)
        if AssistantFAQ.contains(text, unlawful) { return .unlawful }
        if AssistantFAQ.contains(text, investment) { return .investmentPicks }
        if AssistantFAQ.contains(text, taxOrLegal) { return .taxOrLegal }
        return nil
    }

    /// What FinSight says instead of answering.
    static func reply(for topic: Topic) -> String {
        switch topic {
        case .investmentPicks:
            String(localized: "I can't recommend specific stocks, funds or crypto. A licensed financial adviser can help with investment choices. What I can do is show how much you could set aside each month: try \"How can I save more this month?\"")
        case .taxOrLegal:
            String(localized: "I can't give tax or legal advice. For that, please talk to a licensed professional. I can help with your spending, budgets and savings goals.")
        case .unlawful:
            String(localized: "I can't help with that. I can help with your spending, budgets, savings goals and recurring charges.")
        }
    }

    /// Shown with the chat and under every money answer.
    static var disclaimer: String {
        String(localized: "FinSight AI gives general money guidance based on your data, not financial advice.")
    }

    /// When the on-device model declines to answer.
    static var modelRefusal: String {
        String(localized: "I can't help with that one. I can answer questions about your spending, budgets, savings goals and recurring charges.")
    }

    /// When Apple's on-device safety checks block the question or the answer.
    static var safetyBlocked: String {
        String(localized: "Apple's on-device safety checks stopped this request. Try asking about your spending, budgets or savings goals.")
    }

    private static let investment = [
        "stock", "stocks", "share price", "crypto", "cryptocurrency", "bitcoin", "btc", "ethereum", "eth",
        "forex", "day trading", "which fund", "what fund", "mutual fund", "etf", "etfs", "uitf", "invest in", "should i invest",
        "best investment", "what to invest", "where to invest", "saan mag invest", "anong stock", "anong crypto"
    ]
    private static let taxOrLegal = [
        "tax", "taxes", "tax return", "file my taxes", "bir", "buwis", "itr", "lawyer", "attorney", "legal", "lawsuit", "sue", "abogado"
    ]
    private static let unlawful = [
        "launder", "laundering", "money laundering", "evade", "evasion", "tax evasion", "commit fraud", "scam someone", "steal", "fake receipt", "fake receipts", "nakaw", "magnakaw"
    ]
}
