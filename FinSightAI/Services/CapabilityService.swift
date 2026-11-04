import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Why the on-device model can't run, with copy specific enough to act on.
enum AIUnavailableReason: Equatable, Sendable {
    /// The hardware can't run Apple Intelligence. Nothing the user can do.
    case deviceNotEligible
    /// Eligible, but switched off in Settings.
    case appleIntelligenceNotEnabled
    /// Switched on, but the model is still downloading or preparing.
    case modelNotReady
    /// Built with an SDK that has no on-device model API.
    case unsupportedSDK
    /// A reason added by a newer OS than this app knows about.
    case unknown

    var title: String {
        switch self {
        case .deviceNotEligible: String(localized: "AI isn't supported on this device")
        case .appleIntelligenceNotEnabled: String(localized: "Apple Intelligence is turned off")
        case .modelNotReady: String(localized: "The on-device model is getting ready")
        case .unsupportedSDK: String(localized: "AI isn't supported by this build")
        case .unknown: String(localized: "AI isn't available right now")
        }
    }

    var message: String {
        switch self {
        case .deviceNotEligible: String(localized: "This device doesn't support Apple Intelligence.")
        case .appleIntelligenceNotEnabled: String(localized: "Turn on Apple Intelligence in Settings to get AI insights.")
        case .modelNotReady: String(localized: "The on-device model is still downloading. Try again in a little while.")
        case .unsupportedSDK: String(localized: "Apple Intelligence requires a newer Apple SDK than the one used to build this app.")
        case .unknown: String(localized: "The on-device AI model isn't available right now.")
        }
    }

    /// What the user can do next, if anything.
    var actionHint: String? {
        switch self {
        case .deviceNotEligible, .unsupportedSDK: nil
        case .appleIntelligenceNotEnabled: String(localized: "Open Settings › Apple Intelligence & Siri, turn it on, then come back.")
        case .modelNotReady: String(localized: "Keep the device on Wi-Fi and charging, then check again.")
        case .unknown: String(localized: "Check again in a moment.")
        }
    }

    /// Whether checking again later can change the outcome.
    var isRecoverable: Bool {
        switch self {
        case .deviceNotEligible, .unsupportedSDK: false
        case .appleIntelligenceNotEnabled, .modelNotReady, .unknown: true
        }
    }

    var systemImage: String {
        switch self {
        case .deviceNotEligible, .unsupportedSDK: "iphone.slash"
        case .appleIntelligenceNotEnabled: "sparkles.slash"
        case .modelNotReady: "arrow.down.circle"
        case .unknown: "exclamationmark.triangle"
        }
    }
}

enum AIAvailability: Equatable, Sendable {
    case available
    case unavailable(AIUnavailableReason)

    var isAvailable: Bool { self == .available }

    var reason: AIUnavailableReason? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    var message: String? { reason?.message }
}

protocol CapabilityService: Sendable {
    var aiAvailability: AIAvailability { get }
}

/// Reads the real on-device model state instead of assuming every iOS 26 device can run it.
struct DefaultCapabilityService: CapabilityService {
    var aiAvailability: AIAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(Self.reason(for: reason))
        }
        #else
        return .unavailable(.unsupportedSDK)
        #endif
    }

    #if canImport(FoundationModels)
    static func reason(for reason: SystemLanguageModel.Availability.UnavailableReason) -> AIUnavailableReason {
        switch reason {
        case .deviceNotEligible: .deviceNotEligible
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .modelNotReady: .modelNotReady
        @unknown default: .unknown
        }
    }

    static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        Self.reason(for: reason).message
    }
    #endif
}

/// A fixed answer, for tests and previews.
struct StaticCapabilityService: CapabilityService {
    let aiAvailability: AIAvailability
}
