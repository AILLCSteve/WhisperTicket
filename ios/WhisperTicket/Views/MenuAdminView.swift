import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct MenuAdminView: View {
    @Environment(\.appServices) var services
    @State private var currentMenu: MenuV1? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showPDFPicker = false
    @State private var showPhotoPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var isImporting = false
    @State private var importResult: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.chromeBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    importButtonsRow

                    if isImporting {
                        importingOverlay
                    }

                    if let menu = currentMenu {
                        menuContent(menu: menu)
                    } else if isLoading {
                        Spacer()
                        ProgressView("Loading menu…").tint(Color.chromePrimary)
                        Spacer()
                    } else {
                        emptyState
                    }
                }
            }
            .navigationTitle("Menu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.chromeBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reload") { Task { await loadMenu() } }
                        .foregroundStyle(Color.chromePrimary)
                        .disabled(isLoading || isImporting)
                }
            }
            .task { await initialLoad() }
            .alert("Import Complete", isPresented: Binding(
                get: { importResult != nil },
                set: { if !$0 { importResult = nil } }
            )) {
                Button("OK") { importResult = nil }
            } message: {
                Text(importResult ?? "")
            }
            .alert("Error", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            // PDF / file picker
            .fileImporter(
                isPresented: $showPDFPicker,
                allowedContentTypes: [.pdf, .image, .jpeg, .png, .heic],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let ext = url.pathExtension.lowercased()
                    let fileType: MenuImportFileType = ext == "pdf" ? .pdf : .image
                    Task { await runImport(url: url, fileType: fileType) }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            // Photo library picker
            .photosPicker(
                isPresented: $showPhotoPicker,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .onChange(of: selectedPhotoItem) { _, newItem in
                guard let newItem else { return }
                Task { await runPhotoImport(item: newItem) }
            }
        }
    }

    // MARK: - Import buttons row

    private var importButtonsRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ImportOptionButton(
                    icon: "doc.fill",
                    label: "PDF Menu",
                    sublabel: "Files, Safari print-to-PDF",
                    color: Color.chromePrimary
                ) {
                    showPDFPicker = true
                }

                ImportOptionButton(
                    icon: "camera.fill",
                    label: "Photo / Screenshot",
                    sublabel: "Camera roll or screenshot",
                    color: Color.chromeTeal
                ) {
                    showPhotoPicker = true
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Importing overlay

    private var importingOverlay: some View {
        HStack(spacing: 10) {
            ProgressView().tint(Color.chromePrimary).scaleEffect(0.85)
            Text("Importing menu — scanning for items…")
                .font(.callout)
                .foregroundStyle(Color.chromeSilverLow)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.chromeSurface)
    }

    // MARK: - Menu content

    private func menuContent(menu: MenuV1) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Summary card
                VStack(alignment: .leading, spacing: 8) {
                    ChromeSectionHeader(title: "Menu Summary", systemImage: "menucard.fill")
                    HStack(spacing: 24) {
                        MetricPill(label: "Categories", value: "\(menu.categories.count)")
                        MetricPill(label: "Total Items", value: "\(menu.categories.flatMap { $0.items }.count)")
                        MetricPill(label: "Version", value: "v\(menu.version)")
                    }
                }
                .padding(14)
                .chromeCard(cornerRadius: 14)

                // Categories
                ForEach(menu.categories) { category in
                    VStack(alignment: .leading, spacing: 10) {
                        ChromeSectionHeader(title: category.name, systemImage: "list.bullet")
                        ForEach(category.items) { item in
                            MenuItemRow(item: item, currency: menu.currency)
                            if item.id != category.items.last?.id {
                                Divider().background(Color.chromeSilverLow.opacity(0.12))
                            }
                        }
                    }
                    .padding(14)
                    .chromeCard(cornerRadius: 14)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "menucard")
                .font(.system(size: 48))
                .foregroundStyle(Color.chromeSilverLow.opacity(0.4))
            Text("No Menu Loaded")
                .font(.title3.bold())
                .foregroundStyle(Color.chromeSilverHigh)
            Text("Use the buttons above to import a menu from a PDF saved in Safari or from a photo of your menu.")
                .font(.callout)
                .foregroundStyle(Color.chromeSilverLow)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Load Demo Menu") { Task { await loadMenu() } }
                .buttonStyle(.borderedProminent)
                .tint(Color.chromePrimary)
            Spacer()
        }
    }

    // MARK: - Actions

    private func initialLoad() async {
        currentMenu = services.menuStore.menu
        if currentMenu == nil { await loadMenu() }
    }

    private func loadMenu() async {
        isLoading = true
        do {
            try await services.menuStore.loadMenu()
            currentMenu = services.menuStore.menu
        } catch {
            currentMenu = services.menuStore.menu
            if currentMenu == nil { errorMessage = error.localizedDescription }
        }
        isLoading = false
    }

    private func runImport(url: URL, fileType: MenuImportFileType) async {
        isImporting = true
        let outcome = await services.menuImporter.importMenu(from: url, fileType: fileType)
        handleImportOutcome(outcome)
        isImporting = false
    }

    private func runPhotoImport(item: PhotosPickerItem) async {
        isImporting = true
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "Could not load image data from photo library."
                isImporting = false
                return
            }
            let unified = services.menuImporter as? UnifiedMenuImportService
            let outcome: MenuImportResult
            if let unified {
                outcome = await unified.importMenu(from: data, name: "Photo Menu")
            } else {
                // Fallback: save to temp file and use the standard URL path.
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".jpg")
                try data.write(to: tempURL)
                outcome = await services.menuImporter.importMenu(from: tempURL, fileType: .image)
                try? FileManager.default.removeItem(at: tempURL)
            }
            handleImportOutcome(outcome)
        } catch {
            errorMessage = "Photo import failed: \(error.localizedDescription)"
        }
        isImporting = false
        selectedPhotoItem = nil
    }

    private func handleImportOutcome(_ outcome: MenuImportResult) {
        switch outcome {
        case .success(let menu):
            services.menuStore.saveMenu(menu)
            currentMenu = menu
            let itemCount = menu.categories.flatMap { $0.items }.count
            importResult = "Imported \(menu.categories.count) categories with \(itemCount) items."
        case .failure(let message):
            errorMessage = message
        }
    }
}

// MARK: - Supporting Views

private struct ImportOptionButton: View {
    let icon: String
    let label: String
    let sublabel: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(color)
                Text(label)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(sublabel)
                    .font(.caption2)
                    .foregroundStyle(Color.chromeSilverLow)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .chromeCard(cornerRadius: 14, glowColor: color.opacity(0.3), glowRadius: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(color.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.bold().monospacedDigit())
                .foregroundStyle(Color.chromePrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Color.chromeSilverLow)
        }
    }
}

private struct MenuItemRow: View {
    let item: MenuItem
    let currency: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                if !item.description.isEmpty {
                    Text(item.description)
                        .font(.caption)
                        .foregroundStyle(Color.chromeSilverLow)
                }
            }
            Spacer()
            Text(item.price, format: .currency(code: currency))
                .font(.callout.monospacedDigit())
                .foregroundStyle(Color.chromePrimary)
        }
        .padding(.vertical, 4)
    }
}
