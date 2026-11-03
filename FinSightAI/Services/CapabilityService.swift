import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum AIAvailability: Equatable {
    case available
    case unavailable(String)
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
            return .unavailable(Self.message(for: reason))
        }
        #else
        return .unavailable("Apple Intelligence requires a newer Apple SDK than the one used to build this app.")
        #endif
    }

    #if canImport(FoundationModels)
    static func message(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to get AI insights."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again in a little while."
        @unknown default:
            return "The on-device AI model isn't available right now."
        }
    }
    #endif
}
