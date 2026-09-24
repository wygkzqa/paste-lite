import SwiftUI

/// One shared material for both compact panel layouts; rows stay inexpensive to render.
struct ClipboardGlass: ViewModifier {
    static let panelCornerRadius: CGFloat = 24
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let usesGradientBackground: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let surface = content.background {
            if usesGradientBackground {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color(red: 0.16, green: 0.23, blue: 0.40),
                               Color(red: 0.29, green: 0.20, blue: 0.43),
                               Color(red: 0.14, green: 0.29, blue: 0.38)]
                            : [Color(red: 0.72, green: 0.85, blue: 1.00),
                               Color(red: 0.88, green: 0.80, blue: 0.99),
                               Color(red: 0.68, green: 0.84, blue: 0.96)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .opacity(reduceTransparency ? 1 : 0.8)
                    .allowsHitTesting(false)
            }
        }
        if reduceTransparency {
            surface.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            surface.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(
                            LinearGradient(colors: [.white.opacity(colorScheme == .dark ? 0.3 : 0.7), .white.opacity(0.06)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        } else {
            surface.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
        }
    }
}
