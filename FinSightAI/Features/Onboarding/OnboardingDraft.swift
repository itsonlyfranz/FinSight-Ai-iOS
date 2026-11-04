import Foundation

/// Everything the first-run flow collects. Nothing is written until `AppContext.completeOnboarding`.
struct OnboardingDraft {
    struct Goal: Identifiable, Equatable {
        var id = UUID()
        var name = ""
        var amount = ""

        var isValid: Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (AmountParser.parse(amount) ?? 0) > 0
        }
    }

    enum Step: Int, CaseIterable, Comparable {
        case welcome, region, income, goals, preferences, privacy

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
        var next: Step? { Step(rawValue: rawValue + 1) }
        var previous: Step? { Step(rawValue: rawValue - 1) }
    }

    static let goalLimit = 1...3

    var name = ""
    var role = ""
    var currencyCode = CurrencyFormatter.currencyCode(for: .current)
    var firstWeekday = Calendar.current.firstWeekday
    var income = ""
    var goals: [Goal] = [Goal()]
    /// Off by default: sample data is strictly opt-in.
    var loadSampleData = false
    /// Off by default: the system permission prompt only appears if the person turns this on.
    var enableNotifications = false

    var incomeAmount: Decimal? {
        guard let amount = AmountParser.parse(income), amount > 0 else { return nil }
        return amount
    }

    var goalsAreValid: Bool {
        Self.goalLimit.contains(goals.count) && goals.allSatisfy(\.isValid)
    }

    var canAddGoal: Bool { goals.count < Self.goalLimit.upperBound }
    var canRemoveGoal: Bool { goals.count > Self.goalLimit.lowerBound }

    mutating func addGoal() {
        guard canAddGoal else { return }
        goals.append(Goal())
    }

    mutating func removeGoal(id: Goal.ID) {
        guard canRemoveGoal else { return }
        goals.removeAll { $0.id == id }
    }

    /// Whether the person can move past `step`; only income and goals have required input.
    func canAdvance(from step: Step) -> Bool {
        switch step {
        case .income: incomeAmount != nil
        case .goals: goalsAreValid
        case .welcome, .region, .preferences, .privacy: true
        }
    }

    var isValid: Bool { Step.allCases.allSatisfy(canAdvance(from:)) }
}

/// The name and role shown in the dashboard greeting, as on Android. Kept in this device's
/// `UserDefaults` only; both are optional.
struct UserProfile: Equatable {
    static let nameKey = "profileName"
    static let roleKey = "profileRole"

    var name: String
    var role: String

    init(name: String = "", role: String = "") {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func load(from defaults: UserDefaults = .standard) -> UserProfile {
        UserProfile(name: defaults.string(forKey: nameKey) ?? "", role: defaults.string(forKey: roleKey) ?? "")
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(name, forKey: Self.nameKey)
        defaults.set(role, forKey: Self.roleKey)
    }

    /// Up to two initials for the avatar ("Mark Santos" → "MS"); nil without a name.
    var initials: String? {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        return letters.isEmpty ? nil : String(letters).uppercased()
    }
}
