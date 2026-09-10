import SwiftUI

enum BloomTheme {
    static let shell = Color(red: 5/255, green: 6/255, blue: 8/255)
    static let surface = Color(red: 20/255, green: 24/255, blue: 32/255)
    static let well = Color(red: 27/255, green: 34/255, blue: 44/255)
    static let raised = Color(red: 36/255, green: 46/255, blue: 60/255)
    static let selected = Color(red: 37/255, green: 56/255, blue: 79/255)
    static let blue = Color(red: 121/255, green: 175/255, blue: 245/255)
    static let primary = Color(red: 49/255, green: 87/255, blue: 128/255)
    static let text = Color(red: 232/255, green: 237/255, blue: 245/255)
    static let muted = Color(red: 170/255, green: 182/255, blue: 198/255)
    static let danger = Color(red: 1, green: 0.57, blue: 0.59)
    static let buttonHeight: CGFloat = 32
    static let iconSize: CGFloat = 14
    static let controlRadius: CGFloat = 12
    static let controlAnimation = Animation.easeOut(duration: 0.12)
    static let layoutAnimation = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.36)
}

private struct BloomExpandedKey: EnvironmentKey { static let defaultValue = false }
private struct BloomReduceMotionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
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
    var color: Color = BloomTheme.surface
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(color)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(LinearGradient(colors: [.white.opacity(0.065), .clear],
                                               startPoint: .top, endPoint: .bottom), lineWidth: 0.7)
                        .opacity(color == .clear ? 0 : 1)
                }
        }
    }
}

struct BloomButtonStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(enabled ? BloomTheme.text : BloomTheme.muted.opacity(0.65))
            .padding(.horizontal, 14).frame(minHeight: BloomTheme.buttonHeight)
            .modifier(BloomSurface(color: primary && enabled ? BloomTheme.primary : hovering && enabled ? BloomTheme.selected : BloomTheme.raised, radius: BloomTheme.controlRadius))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : BloomTheme.controlAnimation, value: hovering)
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
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.bloomReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: BloomTheme.iconSize, weight: .regular))
                .frame(width: BloomTheme.buttonHeight, height: BloomTheme.buttonHeight)
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
            HStack(spacing: 12) {
                configuration.label
                Spacer(minLength: 12)
                Capsule()
                    .fill(configuration.isOn ? BloomTheme.blue : BloomTheme.muted.opacity(0.22))
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(BloomTheme.text)
                            .frame(width: 20, height: 20).padding(2)
                    }
                    .frame(width: 44, height: 24)
                    .animation(reduceMotion || systemReduceMotion ? nil : .easeInOut(duration: 0.18), value: configuration.isOn)
            }
            .frame(minHeight: 32)
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
    var weight: Font.Weight = .regular
    var animatableData: CGFloat {
        get { size }
        set { size = newValue }
    }
    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight)) }
}
