import SwiftUI

enum AppTheme {
    static let surfaceTop = Color(red: 0.96, green: 0.98, blue: 0.95)
    static let surfaceBottom = Color(red: 0.88, green: 0.94, blue: 0.90)
    static let primary = Color(red: 0.10, green: 0.42, blue: 0.31)
    static let secondary = Color(red: 0.24, green: 0.55, blue: 0.46)
    static let accent = Color(red: 0.90, green: 0.61, blue: 0.22)
    static let ink = Color(red: 0.11, green: 0.16, blue: 0.13)
    static let mutedInk = Color(red: 0.33, green: 0.40, blue: 0.36)
    static let card = Color.white.opacity(0.86)

    static let backgroundGradient = LinearGradient(
        colors: [surfaceTop, surfaceBottom],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
