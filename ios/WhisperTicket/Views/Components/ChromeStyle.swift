import SwiftUI

// MARK: - Chrome Design System
// "Liquid chrome" aesthetic: dark glass cards, gradient chrome borders,
// colored glow shadows, shimmer animation. Adapts to system light/dark mode.

// MARK: - Color Tokens

extension Color {
    /// Tinted blue-purple accent — primary interactive elements and glow.
    static let chromePrimary = Color(red: 0.35, green: 0.55, blue: 1.0)
    /// Soft teal — positive states (available, confirmed).
    static let chromeTeal = Color(red: 0.2, green: 0.85, blue: 0.75)
    /// Warm amber — in-progress / sent states.
    static let chromeAmber = Color(red: 1.0, green: 0.65, blue: 0.2)
    /// Chrome silver highlight (high-specularity).
    static let chromeSilverHigh = Color(red: 0.88, green: 0.90, blue: 0.96)
    /// Chrome silver shadow side.
    static let chromeSilverLow = Color(red: 0.55, green: 0.58, blue: 0.68)
}

// MARK: - ViewModifiers

/// Glass-chrome card: translucent material + gradient overlay + chrome border + optional glow shadow.
struct ChromeCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var glowColor: Color = .clear
    var glowRadius: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.chromeSilverHigh.opacity(0.08),
                                        Color.chromePrimary.opacity(0.04),
                                        Color.chromeSilverLow.opacity(0.06),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.chromeSilverHigh.opacity(0.55),
                                Color.chromeSilverHigh.opacity(0.20),
                                Color.chromeSilverLow.opacity(0.10),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: glowRadius > 0 ? glowColor.opacity(0.25) : .clear,
                radius: glowRadius, x: 0, y: 3
            )
    }
}

/// Animated shimmer sweep — use on record button or primary CTA.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1.2

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.35), .clear],
                    startPoint: .init(x: phase, y: 0.1),
                    endPoint: .init(x: phase + 0.6, y: 0.9)
                )
                .frame(width: geo.size.width, height: geo.size.height)
                .allowsHitTesting(false)
            }
            .clipped()
        )
        .onAppear {
            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                phase = 1.2
            }
        }
    }
}

/// Colored double-shadow glow halo — use on active/status elements.
struct GlowRingModifier: ViewModifier {
    var color: Color
    var radius: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.4), radius: radius, x: 0, y: 2)
            .shadow(color: color.opacity(0.15), radius: radius * 2, x: 0, y: 4)
    }
}

// MARK: - View Extensions

extension View {
    /// Glass-chrome card style with optional status glow.
    func chromeCard(cornerRadius: CGFloat = 16, glowColor: Color = .clear, glowRadius: CGFloat = 0) -> some View {
        modifier(ChromeCardModifier(cornerRadius: cornerRadius, glowColor: glowColor, glowRadius: glowRadius))
    }

    /// Animated shimmer sweep (record button, primary CTA).
    func chromeShimmer() -> some View {
        modifier(ShimmerModifier())
    }

    /// Colored glow halo (active/status elements).
    func glowRing(color: Color, radius: CGFloat = 8) -> some View {
        modifier(GlowRingModifier(color: color, radius: radius))
    }

    /// Conditional modifier — applies transform only when condition is true.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Chrome Section Header

/// Drop-in section label with chrome gradient title and icon.
struct ChromeSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.bold())
                .foregroundStyle(Color.chromePrimary)
            Text(title.uppercased())
                .font(.caption.bold())
                .tracking(0.8)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.chromeSilverHigh, .chromeSilverLow],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
        }
    }
}

// MARK: - Chrome Tab Bar

/// Applies frosted-chrome appearance to the system tab bar.
struct ChromeTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterialDark)
            appearance.backgroundColor = UIColor(red: 0.08, green: 0.09, blue: 0.14, alpha: 0.92)
            appearance.stackedLayoutAppearance.selected.iconColor = UIColor(Color.chromePrimary)
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
                .foregroundColor: UIColor(Color.chromePrimary)
            ]
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

extension View {
    func chromeTabBar() -> some View { modifier(ChromeTabBarModifier()) }
}
