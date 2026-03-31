import SwiftUI
import UniformTypeIdentifiers

struct MenuAdminView: View {
    @Environment(\.appServices) var services
    @State private var currentMenu: MenuV1? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showImportPicker = false
    @State private var isImporting = false
    @State private var importResult: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if let menu = currentMenu {
                    List {
                        Section("Restaurant") {
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
                    .listStyle(.insetGrouped)
                } else if isLoading {
                    ProgressView("Loading menu...")
                } else {
                    ContentUnavailableView(
                        "No Menu Loaded",
                        systemImage: "menucard",
                        description: Text("Tap Reload to load the demo menu, or use Import to add a menu from a PDF or image.")
                    )
                }

                if isImporting {
                    ProgressView("Importing menu…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .navigationTitle("Menu")
            .toolbarBackground(.regularMaterial, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reload") {
                        Task { await loadMenu() }
                    }
                    .disabled(isLoading)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showImportPicker = true
                    } label: {
                        Label("Import Menu", systemImage: "square.and.arrow.down")
                    }
                    .disabled(isImporting)
                }
            }
            .task {
                // Show whatever is already in the store (loaded at app startup)
                currentMenu = services.menuStore.menu
                // If not yet loaded, trigger a load
                if currentMenu == nil { await loadMenu() }
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .fileImporter(
                isPresented: $showImportPicker,
                allowedContentTypes: [.pdf, .image, .jpeg, .png],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let fileType: MenuImportFileType = url.pathExtension.lowercased() == "pdf" ? .pdf : .image
                    Task {
                        isImporting = true
                        let outcome = await services.menuImporter.importMenu(from: url, fileType: fileType)
                        switch outcome {
                        case .success(let menu):
                            services.menuStore.saveMenu(menu)
                            currentMenu = menu
                            importResult = "Imported \(menu.categories.count) categories, \(menu.categories.flatMap { $0.items }.count) items"
                        case .failure(let message):
                            importResult = message
                        }
                        isImporting = false
                    }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            .alert("Import Result", isPresented: Binding(
                get: { importResult != nil },
                set: { if !$0 { importResult = nil } }
            )) {
                Button("OK") { importResult = nil }
            } message: {
                Text(importResult ?? "")
            }
        }
    }

    private func loadMenu() async {
        isLoading = true
        do {
            try await services.menuStore.loadMenu()
            currentMenu = services.menuStore.menu
        } catch {
            // Even on error, check if embedded fallback succeeded
            currentMenu = services.menuStore.menu
            if currentMenu == nil {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }
}
