import Foundation

/// Smart help in the transaction editor, on top of `TransactionAssistant`.
extension AppContext {
    /// Loads the on-device model ahead of first use (call once after launch).
    func prewarmAI() {
        aiInsightService.prewarm()
        transactionAssistant.prewarm()
        assistantService.prewarm()
    }

    /// Reads a sentence like "coffee 150 yesterday" into the draft being edited. Returns whether it
    /// found an amount; the draft keeps whatever was recognised either way, so the user can finish it.
    @discardableResult
    func applyQuickAdd(_ text: String, now: Date = .now) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let calendar = settings?.calendar() ?? .current
        let result = await transactionAssistant.parseQuickAdd(trimmed, now: now, calendar: calendar, locale: activeDraft.locale)
        var draft = TransactionDraft(quickAdd: result, locale: activeDraft.locale)
        draft.note = activeDraft.note
        draft.categoryIsUserChosen = result.category?.source == .rule
        activeDraft = draft
        categorySuggestion = result.category
        return result.amount != nil
    }

    /// Suggests a category for the merchant just typed and applies it unless the user already chose one.
    func suggestCategoryForActiveDraft() async {
        let draft = activeDraft
        guard draft.kind == .expense, !draft.categoryIsUserChosen else { return }
        let merchant = draft.merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merchant.isEmpty else {
            applyCategorySuggestion(nil)
            return
        }
        let suggestion = await transactionAssistant.suggestCategory(merchant: merchant, note: draft.note)
        // The user may have kept typing or picked a category while the model worked.
        guard activeDraft.merchantName.trimmingCharacters(in: .whitespacesAndNewlines) == merchant,
              !activeDraft.categoryIsUserChosen else { return }
        applyCategorySuggestion(suggestion)
    }

    /// Shows `suggestion` and applies its category. With no suggestion, a category that an earlier
    /// suggestion applied goes back to the draft default instead of being saved unexplained.
    private func applyCategorySuggestion(_ suggestion: CategorySuggestion?) {
        if let suggestion {
            activeDraft.category = suggestion.category
        } else if let previous = categorySuggestion, activeDraft.category == previous.category {
            activeDraft.category = TransactionDraft().category
        }
        categorySuggestion = suggestion
    }

    /// Cleans bank-style merchant text ("SQ *BLUE BOTTLE #12") in the draft. Hand-written names are untouched.
    func normalizeActiveMerchant() {
        let normalized = MerchantNameCleaner.clean(activeDraft.merchantName)
        if !normalized.isEmpty, normalized != activeDraft.merchantName {
            activeDraft.merchantName = normalized
        }
    }
}
