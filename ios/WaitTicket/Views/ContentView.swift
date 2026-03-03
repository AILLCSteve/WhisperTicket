import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            TableSelectView()
                .tabItem { Label("Tables", systemImage: "tablecells") }
            TicketsListView()
                .tabItem { Label("Tickets", systemImage: "doc.text") }
            MenuAdminView()
                .tabItem { Label("Menu", systemImage: "menucard") }
        }
    }
}
