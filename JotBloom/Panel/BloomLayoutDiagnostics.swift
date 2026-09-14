import SwiftUI

#if DEBUG
private struct BloomLayoutFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
@MainActor enum BloomLayoutDiagnostics { static var frames: [String: CGRect] = [:] }
#endif
extension View {
    @ViewBuilder func bloomMeasure(_ name: String) -> some View {
#if DEBUG
        background(GeometryReader { geometry in
            Color.clear.preference(key: BloomLayoutFrames.self, value: [name: geometry.frame(in: .global)])
        }).onPreferenceChange(BloomLayoutFrames.self) { frames in
            Task { @MainActor in BloomLayoutDiagnostics.frames.merge(frames, uniquingKeysWith: { _, new in new }) }
        }
#else
        self
#endif
    }
}
