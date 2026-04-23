import Foundation

enum AIAvailability: Equatable {
    case available
    case unavailable(String)
}

protocol CapabilityService {
    var aiAvailability: AIAvailability { get }
}

struct DefaultCapabilityService: CapabilityService {
    var aiAvailability: AIAvailability {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return .available
        } else {
            return .unavailable("Apple Intelligence needs iOS 26 or newer.")
        }
        #else
        return .unavailable("Apple Intelligence requires a newer Apple SDK than the one used to build this app.")
        #endif
    }
}
