import SwiftUI

enum BloomTheme {
    /// Dynamic NSColors resolve with the view's appearance, including native editors.
    static func adaptive(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255, alpha: 1)
        })
    }
    static let toggleTrack = adaptive(dark: (17, 23, 32), light: (209, 215, 224))
    static let toggleThumb = adaptive(dark: (174, 187, 207), light: (247, 249, 252))
    static let shell = adaptive(dark: (8, 10, 14), light: (237, 239, 242))
    static let surface = adaptive(dark: (20, 23, 29), light: (246, 247, 249))
    static let well = adaptive(dark: (25, 29, 37), light: (250, 251, 252))
    static let raised = adaptive(dark: (39, 45, 55), light: (252, 253, 254))
    static let selected = adaptive(dark: (20, 47, 86), light: (222, 232, 253))
    static let selectionEnd = adaptive(dark: (21, 68, 173), light: (42, 105, 224))
    static let userBubble = adaptive(dark: (23, 64, 132), light: (218, 232, 255))
    static let blue = adaptive(dark: (59, 125, 255), light: (30, 93, 224))
    static let primary = adaptive(dark: (25, 85, 226), light: (66, 123, 241))
    static let text = adaptive(dark: (237, 240, 246), light: (36, 42, 52))
    static let muted = adaptive(dark: (174, 187, 207), light: (97, 107, 123))
    static let danger = adaptive(dark: (255, 145, 150), light: (183, 38, 62))
    static let buttonStroke: CGFloat = 0.75
    static let surfaceStroke: CGFloat = 0.5
    static let buttonEdge = LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
    static let buttonHeight: CGFloat = 34
    static let iconSize: CGFloat = 16
    static let controlRadius: CGFloat = 12
    static let controlAnimation = Animation.easeOut(duration: 0.16)
    static let selectionAnimation = Animation.timingCurve(0.35, 0, 0.20, 1, duration: 0.44)
    static let layoutAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.36)

}

private struct BloomVisibleKey: EnvironmentKey { static let defaultValue = false }
private struct BloomExpandedKey: EnvironmentKey { static let defaultValue = false }
private struct BloomReduceMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var bloomVisible: Bool {
        get { self[BloomVisibleKey.self] }
        set { self[BloomVisibleKey.self] = newValue }
    }
    var bloomReduceMotion: Bool {
        get { self[BloomReduceMotionKey.self] }
        set { self[BloomReduceMotionKey.self] = newValue }
    }
    var bloomExpanded: Bool {
        get { self[BloomExpandedKey.self] }
        set { self[BloomExpandedKey.self] = newValue }
    }
}

struct BloomSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var color: Color = BloomTheme.surface
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(color)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.016 : 0.24), .black.opacity(colorScheme == .dark ? 0.018 : 0.012)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .opacity(color == .clear ? 0 : 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(LinearGradient(colors: colorScheme == .dark ? [.white.opacity(0.10), .white.opacity(0.025)] : [.white.opacity(0.85), .black.opacity(0.065)],
                                               startPoint: .top, endPoint: .bottom), lineWidth: BloomTheme.surfaceStroke)
                        .opacity(color == .clear ? 0 : 1)
                }
        }
    }
}

/// Continuous color drift with independent phases; only accent actions animate.
struct BloomAccent: View {
    @Environment(\.colorScheme) private var colorScheme
    var ai = false
    var moving = false
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @Environment(\.bloomVisible) private var visible
    @Environment(\.isEnabled) private var enabled
    @State private var phase = Double.random(in: 0...100)
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !moving || reduceMotion || !visible || !enabled)) { context in
            let time = moving && !reduceMotion && enabled ? context.date.timeIntervalSinceReferenceDate * 0.32 + phase : phase
            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                LinearGradient(colors: colorScheme == .light
                    ? (ai ? [Color(red: 0.50, green: 0.23, blue: 0.86), Color(red: 0.65, green: 0.24, blue: 0.92)]
                          : [Color(red: 0.19, green: 0.34, blue: 0.94), Color(red: 0.08, green: 0.51, blue: 0.91)])
                    : ai
                    ? [Color(red: 0.28, green: 0.05, blue: 0.68), Color(red: 0.49, green: 0.07, blue: 0.85)]
                    : [Color(red: 0.06, green: 0.13, blue: 0.78), Color(red: 0.01, green: 0.30, blue: 0.77)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(RadialGradient(colors: [ai ? Color(red: colorScheme == .light ? 0.72 : 0.62, green: colorScheme == .light ? 0.42 : 0.25, blue: 0.98) : Color(red: colorScheme == .light ? 0.38 : 0.23, green: colorScheme == .light ? 0.49 : 0.32, blue: 1), .clear],
                    center: UnitPoint(x: 0.30 + 0.32 * sin(time * 0.73), y: 0.25 + 0.58 * cos(time * 0.47)),
                    startRadius: 0, endRadius: width * 0.70))
                .overlay(RadialGradient(colors: [ai ? Color(red: 0.82, green: colorScheme == .light ? 0.32 : 0.08, blue: colorScheme == .light ? 0.90 : 0.82).opacity(0.82) : Color(red: colorScheme == .light ? 0.18 : 0, green: colorScheme == .light ? 0.66 : 0.58, blue: colorScheme == .light ? 0.96 : 0.88).opacity(0.84), .clear],
                    center: UnitPoint(x: 0.76 + 0.28 * cos(time * 0.61), y: 0.65 + 0.56 * sin(time * 0.53)),
                    startRadius: 0, endRadius: width * 0.55))
            }
        }.accessibilityHidden(true)
    }
}

struct BloomSelectionSurface: View {
    var radius: CGFloat = 12
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [BloomTheme.primary, BloomTheme.selectionEnd], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(BloomTheme.buttonEdge, lineWidth: BloomTheme.buttonStroke))
    }
}

struct BloomButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var primary = false
    var ai = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BloomTypography.font(12, role: .label))
            .foregroundStyle(enabled ? ((primary || ai) ? Color.white : BloomTheme.text) : (colorScheme == .light && (primary || ai) ? Color.white.opacity(0.5) : BloomTheme.muted.opacity(0.6)))
            .padding(.horizontal, 14).frame(minHeight: BloomTheme.buttonHeight)
            .background {
                ZStack {
                    if primary || ai { BloomAccent(ai: ai, moving: true).opacity(enabled ? 1 : colorScheme == .light ? 0.72 : 0.35) }
                    else { LinearGradient(colors: [BloomTheme.raised, BloomTheme.raised.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing) }
                    Color.white.opacity(hovering && enabled ? 0.035 : 0)
                }
                .clipShape(RoundedRectangle(cornerRadius: BloomTheme.controlRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: BloomTheme.controlRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: primary || ai ? [.white.opacity(0.16), .clear] : colorScheme == .dark ? [.white.opacity(0.08), .clear] : [.white.opacity(0.95), .black.opacity(0.07)], startPoint: .top, endPoint: .bottom), lineWidth: BloomTheme.buttonStroke))
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : BloomTheme.controlAnimation, value: hovering)
    }
}

struct BloomActionLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 6) {
            BloomSymbol(symbol, size: 16).frame(width: symbol == "chevron.left" ? 6 : 16)
            Text(title).fixedSize()
        }
    }
}

/// A shared desktop hit area; the compact notch navigation keeps its own metrics.
struct BloomIconButton: View {
    let title: String
    let symbol: String
    var destructive = false
    var active = false
    var raised = false
    var helpText: String? = nil
    var size: CGFloat = BloomTheme.buttonHeight
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            BloomSymbol(symbol, size: BloomTheme.iconSize)
                .frame(width: size, height: size)
                .contentShape(RoundedRectangle(cornerRadius: BloomTheme.controlRadius))
                .accessibilityHidden(true)
        }
        .buttonStyle(BloomIconPressStyle())
        .foregroundStyle(!enabled ? BloomTheme.muted.opacity(0.45) : destructive && hovering ? BloomTheme.danger : active ? BloomTheme.blue : hovering ? BloomTheme.text : BloomTheme.muted)
        .background(RoundedRectangle(cornerRadius: BloomTheme.controlRadius, style: .continuous)
            .fill(hovering && enabled ? BloomTheme.selected : raised ? BloomTheme.raised : .clear))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : BloomTheme.controlAnimation, value: hovering)
        .help(helpText ?? title)
        .accessibilityLabel(title)
    }
}

private struct BloomIconPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// Draw both parts in SwiftUI: a nonactivating panel must not depend on NSSwitch
/// receiving a later activation/redraw before its thumb becomes visible.
struct BloomToggleStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .top, spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                ZStack(alignment: .leading) {
                    Capsule().fill(BloomTheme.toggleTrack)
                    if configuration.isOn { BloomAccent().clipShape(Capsule()) }
                    Capsule().strokeBorder(.white.opacity(configuration.isOn ? 0.14 : 0.07), lineWidth: BloomTheme.buttonStroke)
                    Circle().fill(configuration.isOn ? Color(red: 241/255, green: 245/255, blue: 252/255) : BloomTheme.toggleThumb)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.10), radius: 0.5, y: 0.5)
                        .offset(x: configuration.isOn ? 18 : 3)
                }
                .frame(width: 37, height: 22)
                .animation(reduceMotion || systemReduceMotion ? nil : .easeInOut(duration: 0.16), value: configuration.isOn)
            }
            .frame(minHeight: 22, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        }
    }
}

/// Explicitly interpolates type size alongside the panel's continuous height change.
struct BloomType: AnimatableModifier {
    var size: CGFloat
    var weight: Font.Weight = .light
    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }
    func body(content: Content) -> some View { content.font(BloomTypography.font(size, role: weight == .light ? .body : .label)) }
}
