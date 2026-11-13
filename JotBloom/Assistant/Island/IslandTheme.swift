import SwiftUI
import JotBloomCore

enum IslandLayout {
    static let cardWidth: CGFloat = 420
    static let cardInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 12
    static let buttonSpacing: CGFloat = 8
    static let buttonHeight: CGFloat = 30
    static let floatingCardRadius: CGFloat = 24
    static let attachedCardRadius: CGFloat = 28
    static let cameraClearance: CGFloat = 28
}

enum IslandTheme {
    static let background = Color.black
    static let text = Color.white
    static let secondaryText = Color.white.opacity(0.68)
    static let hairline = Color.white.opacity(0.12)
    static let secondaryButton = Color.white.opacity(0.14)
    static let statusBlue = Color(red: 0.44, green: 0.73, blue: 1)
    static let statusOrange = Color(red: 1, green: 0.67, blue: 0.30)
    static let statusGreen = Color(red: 0.42, green: 0.85, blue: 0.55)
    static let statusRed = Color(red: 1, green: 0.45, blue: 0.47)
    // Same palette as NotchFeedbackView, with a finite breathing animation.
    static let glow = LinearGradient(colors: [
        Color(red: 175/255, green: 240/255, blue: 1),
        Color(red: 26/255, green: 88/255, blue: 222/255),
        Color(red: 220/255, green: 163/255, blue: 1),
        Color(red: 147/255, green: 56/255, blue: 238/255), statusBlue
    ], startPoint: .leading, endPoint: .trailing)
    static let compactFont = BloomTypography.font(12, role: .label)
    static let titleFont = BloomTypography.font(14, role: .label)
    static let bodyFont = BloomTypography.font(12, role: .body)
    static let auxiliaryFont = BloomTypography.font(11, role: .body)
    static func color(_ tone: IslandTone) -> Color {
        switch tone { case .blue: return statusBlue; case .orange: return statusOrange
        case .green: return statusGreen; case .red: return statusRed }
    }
}
