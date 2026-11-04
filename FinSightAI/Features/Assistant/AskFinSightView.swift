import SwiftUI

/// The Ask FinSight chat: a money coach that answers from the user's own data, with the on-device
/// model where Apple Intelligence is available and quick answers everywhere else.
struct AskFinSightView: View {
    @Environment(AppContext.self) private var appContext
    @State private var draft = ""
    @State private var confirmingClear = false
    @State private var errorMessage: String?
    /// Re-reads the model's availability ("Check Again") without relaunching.
    @State private var availabilityToken = 0
    @FocusState private var isInputFocused: Bool

    private static let bottomID = "chat-bottom"

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                        header
                        modeBanner
                        if appContext.chatMessages.isEmpty {
                            welcome
                        }
                        ForEach(appContext.chatMessages) { message in
                            ChatBubble(message: message)
                                .id(message.id)
                        }
                        if appContext.isAssistantResponding {
                            pendingReply
                        }
                        Color.clear.frame(height: 1).id(Self.bottomID)
                    }
                    .padding(AppTheme.Spacing.lg)
                }
                .scrollDismissesKeyboard(.interactively)
                .background(AppTheme.backgroundGradient.ignoresSafeArea())
                .onChange(of: appContext.chatMessages.count) { _, _ in scrollToBottom(proxy) }
                .onChange(of: appContext.assistantPartialReply) { _, _ in scrollToBottom(proxy, animated: false) }
                .onAppear { scrollToBottom(proxy, animated: false) }
            }
            .safeAreaInset(edge: .bottom) { composer }
            .navigationTitle("Ask")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                if !appContext.chatMessages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Clear chat", systemImage: "trash") { confirmingClear = true }
                            .disabled(appContext.isAssistantResponding)
                    }
                }
            }
            .confirmationDialog("Clear the chat?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Clear chat", role: .destructive) {
                    do { try appContext.clearChat() } catch { errorMessage = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes every message in this conversation from this device.")
            }
            .alert("Something went wrong", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: appContext.chatMessages.count) { old, new in new > old }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Ask FinSight")
                .font(.title2.bold())
                .foregroundStyle(AppTheme.ink)
                .accessibilityAddTraits(.isHeader)
            Text("Your on-device money coach")
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedInk)
        }
    }

    @ViewBuilder
    private var modeBanner: some View {
        let mode = currentMode
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            switch mode {
            case .onDevice:
                Label("On-device AI · your data stays on this iPhone", systemImage: "lock.shield")
                    .font(AppTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.primary)
            case .quickAnswers(let reason):
                Label(reason.title, systemImage: reason.systemImage)
                    .font(AppTheme.Typography.headline)
                    .foregroundStyle(AppTheme.ink)
                Text("Quick answers still work: they're worked out from your data on this device, without AI.")
                    .foregroundStyle(AppTheme.mutedInk)
                if let hint = reason.actionHint {
                    Text(hint)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                }
                if reason.isRecoverable {
                    Button("Check Again") { availabilityToken += 1 }
                        .buttonStyle(.bordered)
                        .tint(AppTheme.primary)
                }
            }
            Label(AssistantGuardrails.disclaimer, systemImage: "info.circle")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(AppTheme.mutedInk)
        }
        .finSightCard(surface: mode == .onDevice ? AppTheme.cardSurface : AppTheme.cardTintRisk)
        .accessibilityElement(children: .contain)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(welcomeText)
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.ink)
            Text("Try asking:")
                .font(AppTheme.Typography.caption.weight(.semibold))
                .foregroundStyle(AppTheme.mutedInk)
            ForEach(appContext.suggestedChatPrompts, id: \.self) { prompt in
                Button {
                    send(prompt)
                } label: {
                    Label(prompt, systemImage: "sparkle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.primary)
                .disabled(appContext.isAssistantResponding)
                .accessibilityHint(Text("Asks FinSight this question"))
            }
        }
        .finSightCard()
    }

    private var welcomeText: String {
        let name = UserProfile.load().name
        return name.isEmpty
            ? String(localized: "Hi! I'm FinSight AI, your money coach. Ask me anything about your spending, budgets, savings goals or recurring charges.")
            : String(localized: "Hi \(name)! I'm FinSight AI, your money coach. Ask me anything about your spending, budgets, savings goals or recurring charges.")
    }

    @ViewBuilder
    private var pendingReply: some View {
        if let partial = appContext.assistantPartialReply, !partial.isEmpty {
            ChatBubble(message: ChatMessage(role: .assistant, text: partial, replyKind: nil), isStreaming: true)
        } else {
            HStack {
                FinSightTypingIndicator()
                    .padding(AppTheme.Spacing.sm)
                    .background(AppTheme.cardSurface, in: Capsule())
                Spacer()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("FinSight is writing"))
        }
    }

    private var composer: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            if !appContext.chatMessages.isEmpty && !appContext.isAssistantResponding {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        ForEach(appContext.suggestedChatPrompts, id: \.self) { prompt in
                            Button(prompt) { send(prompt) }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .tint(AppTheme.primary)
                                .font(AppTheme.Typography.caption)
                                .accessibilityHint(Text("Asks FinSight this question"))
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.lg)
                }
                .accessibilityLabel(Text("Suggested questions"))
            }
            HStack(alignment: .bottom, spacing: AppTheme.Spacing.sm) {
                TextField("Ask about your money", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($isInputFocused)
                    .submitLabel(.send)
                    .onSubmit { send(draft) }
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(AppTheme.cardSurface, in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.pill, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.CornerRadius.pill, style: .continuous)
                            .stroke(AppTheme.cardStroke, lineWidth: 1)
                    }
                Button {
                    send(draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(canSend ? AppTheme.primary : AppTheme.mutedInk)
                }
                .disabled(!canSend)
                .accessibilityLabel(Text("Send"))
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(.bar)
    }

    // MARK: - Actions

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !appContext.isAssistantResponding
    }

    /// Reads the availability afresh; `availabilityToken` makes "Check Again" re-render.
    private var currentMode: AssistantMode {
        _ = availabilityToken
        return appContext.assistantMode
    }

    private func send(_ text: String) {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !appContext.isAssistantResponding else { return }
        draft = ""
        // Not tied to the view: switching tabs mid-answer still saves the reply.
        Task {
            if let reply = await appContext.sendChatMessage(question) {
                AccessibilityNotification.Announcement(reply.text).post()
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }
}

/// One message. The user's sit on the right on the dark hero surface; FinSight's sit on the left
/// on a card, with a note on how the answer was produced.
struct ChatBubble: View {
    let message: ChatMessage
    var isStreaming = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: AppTheme.Spacing.xl) }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                if message.role == .user {
                    Text(message.text)
                        .foregroundStyle(AppTheme.onElevated)
                        .textSelection(.enabled)
                } else {
                    if let badge = badge {
                        Label { Text(badge.title) } icon: { Image(systemName: badge.systemImage) }
                            .font(AppTheme.Typography.caption.weight(.semibold))
                            .foregroundStyle(AppTheme.primary)
                    }
                    FinSightMarkdownView(markdown: message.text, style: .aiInsight)
                    if isStreaming {
                        FinSightTypingIndicator()
                    } else if message.replyKind?.carriesDisclaimer == true {
                        Text("Not financial advice")
                            .font(AppTheme.Typography.caption)
                            .foregroundStyle(AppTheme.mutedInk)
                    }
                }
            }
            .padding(AppTheme.Spacing.sm + 2)
            .background(
                message.role == .user ? AppTheme.surfaceElevated : AppTheme.cardSurface,
                in: RoundedRectangle(cornerRadius: AppTheme.CornerRadius.pill, style: .continuous)
            )
            .overlay {
                if message.role == .assistant {
                    RoundedRectangle(cornerRadius: AppTheme.CornerRadius.pill, style: .continuous)
                        .stroke(AppTheme.cardStroke, lineWidth: 1)
                }
            }
            if message.role == .assistant { Spacer(minLength: AppTheme.Spacing.xl) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var badge: (title: LocalizedStringResource, systemImage: String)? {
        switch message.replyKind {
        case .answer: ("On-device AI", "sparkles")
        case .quickAnswer: ("Quick answer", "bolt.fill")
        case .guardrail, .refusal: ("Outside what I can help with", "hand.raised.fill")
        case nil: nil
        }
    }

    private var accessibilityText: Text {
        let plain = Self.plainText(message.text)
        if message.role == .user { return Text("You: \(plain)") }
        // The brand name reads the same in every language, so it needs no translation.
        var spoken = "FinSight: " + plain
        if let badge { spoken = String(localized: badge.title) + ". " + spoken }
        if !isStreaming, message.replyKind?.carriesDisclaimer == true {
            spoken += " " + String(localized: "Not financial advice")
        }
        return Text(verbatim: spoken)
    }

    /// The text without markdown markers, for VoiceOver.
    static func plainText(_ markdown: String) -> String {
        markdown
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "\n- ", with: "\n")
            .replacingOccurrences(of: "## ", with: "")
    }
}
