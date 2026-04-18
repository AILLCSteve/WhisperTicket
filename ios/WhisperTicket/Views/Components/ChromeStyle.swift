import SwiftUI

// MARK: - Chrome Design System
// "Dark POS Terminal" aesthetic: deep navy base, liquid-chrome glass cards,
// vivid glow accents, animated mic button, live waveform. Dark-mode optimized.

// MARK: - Color Tokens

extension Color {
    /// Deep navy — app background.
    static let chromeBackground = Color(red: 0.05, green: 0.07, blue: 0.12)
    /// Slightly lifted card surface above chromeBackground.
    static let chromeSurface = Color(red: 0.09, green: 0.11, blue: 0.18)
    /// Tinted blue-purple accent — primary interactive elements and glow.
    static let chromePrimary = Color(red: 0.35, green: 0.55, blue: 1.0)
    /// Soft teal — positive states (available, confirmed).
    static let chromeTeal = Color(red: 0.2, green: 0.85, blue: 0.75)
    /// Warm amber — in-progress / sent states.
    static let chromeAmber = Color(red: 1.0, green: 0.65, blue: 0.2)
    /// Deep crimson — recording / allergy danger state.
    static let chromeRed = Color(red: 0.95, green: 0.25, blue: 0.35)
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
                    .fill(Color.chromeSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.chromeSilverHigh.opacity(0.07),
                                        Color.chromePrimary.opacity(0.03),
                                        Color.chromeSilverLow.opacity(0.05),
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
                                Color.chromeSilverHigh.opacity(0.45),
                                Color.chromeSilverHigh.opacity(0.18),
                                Color.chromeSilverLow.opacity(0.08),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: glowRadius > 0 ? glowColor.opacity(0.30) : .clear, radius: glowRadius, x: 0, y: 4)
    }
}

/// Animated shimmer sweep — use on record button or primary CTA.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1.2

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                LinearGradient(
                    colors: [.clear, .white.opacity(0.30), .clear],
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
            .shadow(color: color.opacity(0.45), radius: radius, x: 0, y: 2)
            .shadow(color: color.opacity(0.18), radius: radius * 2, x: 0, y: 5)
    }
}

// MARK: - View Extensions

extension View {
    func chromeCard(cornerRadius: CGFloat = 16, glowColor: Color = .clear, glowRadius: CGFloat = 0) -> some View {
        modifier(ChromeCardModifier(cornerRadius: cornerRadius, glowColor: glowColor, glowRadius: glowRadius))
    }

    func chromeShimmer() -> some View { modifier(ShimmerModifier()) }

    func glowRing(color: Color, radius: CGFloat = 8) -> some View {
        modifier(GlowRingModifier(color: color, radius: radius))
    }

    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

// MARK: - Chrome Section Header

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
                .tracking(1.2)
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

struct ChromeTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear {
            let appearance = UITabBarAppearance()
            appearance.configureWithOpaqueBackground()
            appearance.backgroundEffect = UIBlurEffect(style: .systemChromeMaterialDark)
            appearance.backgroundColor = UIColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 0.96)
            appearance.stackedLayoutAppearance.selected.iconColor = UIColor(Color.chromePrimary)
            appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
                .foregroundColor: UIColor(Color.chromePrimary)
            ]
            appearance.stackedLayoutAppearance.normal.iconColor = UIColor(Color.chromeSilverLow)
            appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
                .foregroundColor: UIColor(Color.chromeSilverLow)
            ]
            UITabBar.appearance().standardAppearance = appearance
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

extension View {
    func chromeTabBar() -> some View { modifier(ChromeTabBarModifier()) }
}

// MARK: - Live Mic Button

/// The centerpiece recording button.
/// Idle: sapphire gradient + soft primary glow.
/// Recording: crimson gradient + three animated pulse rings + scale breathe.
struct LiveMicButton: View {
    let isRecording: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var breathe: Bool = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Pulse rings — only when recording
                if isRecording {
                    PulseRing(color: Color.chromeRed, delay: 0.0, size: 100)
                    PulseRing(color: Color.chromeRed.opacity(0.7), delay: 0.45, size: 100)
                    PulseRing(color: Color.chromeRed.opacity(0.4), delay: 0.9, size: 100)
                }

                // Button disc
                Circle()
                    .fill(
                        isRecording
                            ? LinearGradient(
                                colors: [Color(red: 0.9, green: 0.15, blue: 0.25), Color.chromeRed],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                              )
                            : LinearGradient(
                                colors: [Color(red: 0.25, green: 0.45, blue: 0.95), Color.chromePrimary],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                              )
                    )
                    .frame(width: 88, height: 88)
                    .overlay(
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.25), .clear],
                                    startPoint: .top, endPoint: .center
                                )
                            )
                    )
                    .scaleEffect(isRecording ? (breathe ? 1.05 : 1.0) : 1.0)
                    .shadow(
                        color: isRecording ? Color.chromeRed.opacity(0.55) : Color.chromePrimary.opacity(0.45),
                        radius: 18, x: 0, y: 6
                    )

                // Icon
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(isRecording ? (breathe ? 1.05 : 1.0) : 1.0)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onChange(of: isRecording) { _, recording in
            if recording {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            } else {
                breathe = false
            }
        }
    }
}

// MARK: - Pulse Ring

private struct PulseRing: View {
    let color: Color
    let delay: Double
    let size: CGFloat
    @State private var scale: CGFloat = 0.85
    @State private var opacity: Double = 0.85

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .opacity(opacity)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 1.6)
                    .repeatForever(autoreverses: false)
                    .delay(delay)
                ) {
                    scale = 2.2
                    opacity = 0
                }
            }
    }
}

// MARK: - Audio Waveform

/// 7-bar animated waveform. Bounces when active, flat when idle.
struct AudioWaveformView: View {
    let isActive: Bool
    let noiseLevel: Float
    @State private var phase: Double = 0

    private let barCount = 7

    var barColor: Color {
        if !isActive { return Color.chromeSilverLow.opacity(0.35) }
        if noiseLevel > 0.75 { return Color.chromeRed }
        if noiseLevel > 0.45 { return Color.chromeAmber }
        return Color.chromePrimary
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<barCount, id: \.self) { i in
                let offset = Double(i) * 0.85
                let amplitude = isActive ? max(0.2, Double(noiseLevel) * 0.85 + 0.3) : 0.12
                let h = max(4, 32.0 * amplitude * abs(sin(phase + offset)))

                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .frame(width: 4, height: h)
                    .animation(.linear(duration: 0.07), value: phase)
            }
        }
        .frame(height: 36)
        .onAppear {
            withAnimation(.linear(duration: 0.55).repeatForever(autoreverses: false)) {
                phase = .pi * 2
            }
        }
    }
}

// MARK: - Course Color Dot

struct CourseDot: View {
    let course: CourseFlag

    var color: Color {
        switch course {
        case .appetizer: return .chromeAmber
        case .entree: return .chromePrimary
        case .side: return .chromeTeal
        case .beverage: return Color(red: 0.6, green: 0.35, blue: 0.95)
        case .dessert: return Color(red: 0.95, green: 0.55, blue: 0.75)
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

// MARK: - Chrome Allergy Capsule

struct ChromeAllergyCapsule: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9, weight: .bold))
            Text("ALLERGY")
                .font(.system(size: 9, weight: .black))
                .tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.chromeRed)
        .clipShape(Capsule())
        .shadow(color: Color.chromeRed.opacity(0.5), radius: 4)
    }
}

// MARK: - Confidence Dot

struct ConfidenceDot: View {
    let confidence: Double

    var body: some View {
        if confidence < 0.6 {
            Image(systemName: "questionmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.chromeAmber.opacity(0.8))
        }
    }
}

// MARK: - Status Capsule

struct StatusCapsule: View {
    let status: TicketStatus

    var label: String {
        switch status {
        case .open: return "Open"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .closed: return "Closed"
        }
    }

    var color: Color {
        switch status {
        case .open: return .chromePrimary
        case .sent: return .chromeAmber
        case .delivered: return .chromeTeal
        case .closed: return .chromeSilverLow
        }
    }

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
            .clipShape(Capsule())
    }
}
