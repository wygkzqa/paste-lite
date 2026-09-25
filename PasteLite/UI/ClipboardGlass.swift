import SwiftUI

/// One shared material for both compact panel layouts; rows stay inexpensive to render.
struct ClipboardGlass: ViewModifier {
    static let panelCornerRadius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.3 : 0.7), .white.opacity(0.06)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        }
    }
}
