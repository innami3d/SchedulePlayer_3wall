import SwiftUI

/// Visual feedback only: native focus, shortcuts, drag gestures and hit areas are preserved.
private struct HoverHighlight: ViewModifier {
    enum Style { case control, row, field }
    var style: Style
    var tint: Color
    var enabled: Bool
    var radius: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    private var active: Bool { hovering && enabled && isEnabled }
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(tint.opacity(active ? (style == .field ? 0 : 0.09) : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(tint.opacity(active ? (style == .row ? 0.3 : 0.55) : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: active)
    }
}

extension View {
    func controlHover(tint: Color = .accentColor, enabled: Bool = true) -> some View {
        modifier(HoverHighlight(style: .control, tint: tint, enabled: enabled, radius: 5))
    }
    func rowHover(tint: Color = .accentColor, enabled: Bool = true, radius: CGFloat = 7) -> some View {
        modifier(HoverHighlight(style: .row, tint: tint, enabled: enabled, radius: radius))
    }
    func fieldHover() -> some View {
        modifier(HoverHighlight(style: .field, tint: .accentColor, enabled: true, radius: 5))
    }
}
