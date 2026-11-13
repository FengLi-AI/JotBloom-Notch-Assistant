import SwiftUI

enum IslandMotion {
    static let openCompact = Animation.spring(response: 0.42, dampingFraction: 0.72)
    static let openExpanded = Animation.spring(response: 0.46, dampingFraction: 0.76)
    static let closeExpanded = Animation.spring(response: 0.38, dampingFraction: 0.88)
    static let closeCompact = Animation.spring(response: 0.36, dampingFraction: 0.92)
    static let contentSwap = Animation.spring(response: 0.34, dampingFraction: 0.82)
    static let hover = Animation.spring(response: 0.24, dampingFraction: 0.80)
    static let contentInDelay = 0.08
    static let contentIn = Animation.easeOut(duration: 0.22)
    static let contentOut = Animation.easeIn(duration: 0.12)
    static let shapeCloseDelay = 0.04
    static let floatingCloseDuration = 0.28
    static let floatingClose = Animation.easeInOut(duration: floatingCloseDuration)
    static let reduced = Animation.easeInOut(duration: 0.18)
    static let settleTime = 0.7
    static let glowIn = Animation.easeOut(duration: 0.3)
    static let glowBreath = Animation.easeInOut(duration: 0.7)
}

private struct IslandContentEffect: ViewModifier {
    var opacity: Double
    var blur: CGFloat
    var scale: CGFloat
    var offset: CGFloat
    func body(content: Content) -> some View {
        content.opacity(opacity).blur(radius: blur).scaleEffect(scale).offset(y: offset)
    }
}

extension AnyTransition {
    static var islandContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: IslandContentEffect(opacity: 0, blur: 6, scale: 0.96, offset: 6),
                                 identity: IslandContentEffect(opacity: 1, blur: 0, scale: 1, offset: 0)),
            removal: .modifier(active: IslandContentEffect(opacity: 0, blur: 4, scale: 1, offset: -6),
                               identity: IslandContentEffect(opacity: 1, blur: 0, scale: 1, offset: 0)))
    }
}
