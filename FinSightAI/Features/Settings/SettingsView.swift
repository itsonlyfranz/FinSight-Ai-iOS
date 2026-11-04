import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(AppContext.self) private var appContext
    /// Shows a Done button that calls this, when Settings is presented over another screen.
    var onDone: (() -> Void)?
    @State private var errorMessage: String?
    @State private var confirmingSampleData = false
    @AppStorage(ThemePalette.storageKey) private var paletteRawValue = ThemePalette.deckEmerald.rawValue
    @AppStorage(UserProfile.nameKey) private var profileName = ""
    @AppStorage(UserProfile.roleKey) private var profileRole = ""

    private var currencyCodes: [String] {
        var codes = Set(Locale.commonISOCurrencyCodes)
        codes.insert(appContext.currencyCode)
        return codes.sorted()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Your name (optional)", text: $profileName, prompt: Text("e.g. Mark Santos"))
                        .textContentType(.name)
                    TextField("Role (optional)", text: $profileRole, prompt: Text("e.g. Junior SWE @ Apex Systems"))
                        .textContentType(.jobTitle)
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Shown in your dashboard greeting and used by Ask FinSight. Stays on this device.")
                }

                Section {
                    Picker("Theme", selection: $paletteRawValue) {
                        ForEach(ThemePalette.allCases) { palette in
                            HStack {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(AppTheme.swatch(palette))
                                    .accessibilityHidden(true)
                                Text(palette.displayName)
                            }
                            .tag(palette.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Theme Options")
                } footer: {
                    Text("Follows your iPhone's light or dark appearance.")
                }

                Section {
                    Picker("Currency", selection: Binding(
                        get: { appContext.currencyCode },
                        set: { code in run { try appContext.setCurrency(code: code) } }
                    )) {
                        ForEach(currencyCodes, id: \.self) { code in
                            Text(currencyLabel(code)).tag(code)
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Picker("First day of week", selection: Binding(
                        get: { appContext.settings?.firstWeekday ?? 1 },
                        set: { day in run { try appContext.setFirstWeekday(day) } }
                    )) {
                        ForEach(1...7, id: \.self) { day in
                            Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                        }
                    }
                } header: {
                    Text("Region")
                } footer: {
                    Text("Defaults to your device's region. Changing the currency only changes how amounts are shown; it doesn't convert them.")
                }

                Section("Reminders") {
                    Button("Enable local reminders") {
                        Task {
                            do {
                                if try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
                                    try await NudgeScheduler.refresh(snapshot: .make(context: appContext))
                                }
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    Link("Notification settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                    Text("Recurring due dates, budget thresholds and a weekly digest. Scheduled on this device; delivery depends on system refresh.").font(.caption)
                        .foregroundStyle(AppTheme.mutedInk)
                }

                Section("Money") {
                    NavigationLink {
                        IncomeSourcesView()
                    } label: {
                        row("Income", detail: String(localized: "\(CurrencyFormatter.string(from: appContext.monthlyRecurringIncome))/mo"), systemImage: "banknote.fill")
                    }
                    NavigationLink {
                        BudgetsView()
                    } label: {
                        row("Budgets", detail: String(localized: "\(appContext.budgets.count) set"), systemImage: "target")
                    }
                    NavigationLink {
                        SavingsGoalsView()
                    } label: {
                        row("Savings goals", detail: appContext.savingsGoals.count.formatted(), systemImage: "flag.checkered")
                    }
                }

                Section {
                    ShareLink(
                        item: appContext.csvExport,
                        preview: SharePreview(
                            appContext.csvExport.fileName,
                            image: Image(systemName: "tablecells")
                        )
                    ) {
                        Label("Export transactions (CSV)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(appContext.transactions.isEmpty)
                    .accessibilityHint(Text("Shares all \(appContext.transactions.count) transactions as a CSV file"))
                } header: {
                    Text("Export")
                } footer: {
                    Text("Your data stays on this device. The file is created only when you share it.")
                }

                Section {
                    Button {
                        confirmingSampleData = true
                    } label: {
                        Label("Load sample data", systemImage: "tray.and.arrow.down.fill")
                    }
                    .disabled(!appContext.hasNoData)
                } header: {
                    Text("Sample data")
                } footer: {
                    if appContext.hasNoData {
                        Text("Fills the empty ledger with example transactions, income, budgets and a goal.")
                    } else {
                        Text("Sample data can only be loaded into an empty ledger, so it never mixes with your own.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Settings")
            .toolbar {
                if let onDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
            }
            .confirmationDialog("Load sample data?", isPresented: $confirmingSampleData, titleVisibility: .visible) {
                Button("Load sample data") {
                    run { try appContext.loadSampleData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Adds example transactions, income, budgets and a goal.")
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
    }

    private func row(_ title: LocalizedStringKey, detail: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(detail).foregroundStyle(AppTheme.mutedInk).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private func currencyLabel(_ code: String) -> String {
        if let name = Locale.current.localizedString(forCurrencyCode: code) {
            return "\(code) – \(name)"
        }
        return code
    }

    private func run(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}
