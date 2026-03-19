import SwiftUI

/// Title screen shown on each app launch. Provides shift orientation before entering the floor.
struct WelcomeView: View {
    @Environment(\.appServices) var services
    @Binding var isPresented: Bool

    @State private var openCount = 0
    @State private var inKitchenCount = 0
    @State private var restaurantName = "Applebee's"
    @State private var currentTime = Date()

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.08, blue: 0.12), Color(red: 0.14, green: 0.10, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo area
                VStack(spacing: 12) {
                    Image(systemName: "fork.knife.circle.fill")
                        .font(.system(size: 72))
                        .foregroundStyle(.orange)
                        .shadow(color: .orange.opacity(0.4), radius: 20)

                    Text("WaitTicket")
                        .font(.system(size: 42, weight: .black, design: .rounded))
                        .foregroundStyle(.white)

                    Text(restaurantName)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                        .textCase(.uppercase)
                        .tracking(3)
                }

                Spacer()

                // Live clock
                VStack(spacing: 4) {
                    Text(currentTime, format: .dateTime.hour().minute())
                        .font(.system(size: 56, weight: .thin, design: .rounded))
                        .foregroundStyle(.white)
                        .monospacedDigit()

                    Text(currentTime, format: .dateTime.weekday(.wide).month().day())
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.5))
                        .textCase(.uppercase)
                        .tracking(1)
                }

                Spacer()

                // Shift stats
                HStack(spacing: 0) {
                    StatPill(
                        value: openCount,
                        label: "Open Tables",
                        icon: "tablecells",
                        color: openCount > 0 ? .blue : .secondary
                    )
                    Divider()
                        .frame(height: 40)
                        .background(.white.opacity(0.15))
                    StatPill(
                        value: inKitchenCount,
                        label: "In Kitchen",
                        icon: "flame",
                        color: inKitchenCount > 0 ? .orange : .secondary
                    )
                }
                .background(.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 40)

                Spacer()

                // Start button
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isPresented = false
                    }
                } label: {
                    HStack(spacing: 10) {
                        Text("Start Service")
                            .font(.title3.bold())
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.title2)
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .orange.opacity(0.4), radius: 12, y: 4)
                }
                .padding(.horizontal, 40)

                Spacer(minLength: 48)
            }
        }
        .onReceive(clockTimer) { _ in currentTime = Date() }
        .task { await loadStats() }
    }

    private func loadStats() async {
        if let menu = services.menuStore.menu {
            restaurantName = menu.restaurantId
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
        if let tickets = try? await services.repository.fetchAll() {
            openCount = tickets.filter { $0.ticketStatus == .open }.count
            inKitchenCount = tickets.filter { $0.ticketStatus == .sent }.count
        }
    }
}

private struct StatPill: View {
    let value: Int
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text("\(value)")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}
