import SwiftUI

struct MenuAdminView: View {
    @Environment(\.appServices) var services
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let menu = services.menuStore.menu {
                    List {
                        Section("Restaurant") {
                            LabeledContent("ID", value: menu.restaurantId)
                            LabeledContent("Version", value: "\(menu.version)")
                            LabeledContent("Categories", value: "\(menu.categories.count)")
                            LabeledContent("Total Items", value: "\(menu.categories.flatMap { $0.items }.count)")
                        }
                        ForEach(menu.categories) { category in
                            Section(category.name) {
                                ForEach(category.items) { item in
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(item.name).fontWeight(.medium)
                                            Text(item.description)
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(item.price, format: .currency(code: menu.currency))
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                } else if isLoading {
                    ProgressView("Loading menu...")
                } else {
                    ContentUnavailableView(
                        "No Menu Loaded",
                        systemImage: "menucard",
                        description: Text("Add MenuV1.sample.json to the app bundle.")
                    )
                }
            }
            .navigationTitle("Menu")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reload") {
                        Task {
                            isLoading = true
                            try? await services.menuStore.loadMenu()
                            isLoading = false
                        }
                    }
                }
            }
            .alert("Error", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }
}
