import SwiftUI

struct ContentView: View {
    @State private var showWelcome = true

    var body: some View {
        ZStack {
            // Main app
            TabView {
                FloorView()
                    .tabItem { Label("Floor", systemImage: "tablecells.fill") }

                TicketsListView()
                    .tabItem { Label("Tickets", systemImage: "doc.text.fill") }

                MenuAdminView()
                    .tabItem { Label("Menu", systemImage: "menucard.fill") }
            }

            // Title screen overlay — dismissed once per session
            if showWelcome {
                WelcomeView(isPresented: $showWelcome)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: showWelcome)
    }
}
