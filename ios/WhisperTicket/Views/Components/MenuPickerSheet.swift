import SwiftUI

/// Reusable menu browser / picker used for three flows:
///  • "Add More" and the footer "＋" → add a menu item to the active seat.
///  • "Replace" on an order item → swap it for another menu item.
///  • Disambiguation "Browse menu" → resolve an ambiguous parse.
///
/// It shows optional context-specific `suggestions` at the top (related items or
/// the parser's competing candidates), a live search field over the ENTIRE menu
/// grouped by category, and an always-available "custom item" escape hatch so the
/// server is never blocked by a menu gap.
struct MenuPickerSheet: View {
    let title: String
    let menu: MenuV1
    var suggestions: [MenuItem] = []
    var suggestionsTitle: String = "Suggestions"
    let onSelect: (MenuItem) -> Void
    let onCustom: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredCategories: [(name: String, items: [MenuItem])] {
        let q = trimmedQuery.lowercased()
        guard !q.isEmpty else {
            return menu.categories.map { ($0.name, $0.items) }
        }
        let tokens = q.split(separator: " ").map(String.init)
        return menu.categories.compactMap { cat in
            let items = cat.items.filter { item in
                let name = item.name.lowercased()
                let desc = item.description.lowercased()
                return tokens.allSatisfy { name.contains($0) }
                    || tokens.contains { name.contains($0) || desc.contains($0) }
            }
            return items.isEmpty ? nil : (cat.name, items)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.chromeBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchField

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if !suggestions.isEmpty && trimmedQuery.isEmpty {
                                suggestionsSection
                            }
                            if !trimmedQuery.isEmpty {
                                customItemRow
                            }
                            ForEach(filteredCategories, id: \.name) { group in
                                categorySection(name: group.name, items: group.items)
                            }
                            if filteredCategories.isEmpty && trimmedQuery.isEmpty {
                                Text("Menu is empty.")
                                    .font(.callout)
                                    .foregroundStyle(Color.chromeSilverLow)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.chromeBackground, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.chromeSilverLow)
                }
            }
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.callout)
                .foregroundStyle(Color.chromeSilverLow)
            TextField("Search the menu…", text: $query)
                .font(.callout)
                .foregroundStyle(.white)
                .tint(Color.chromePrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.chromeSilverLow.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.chromeSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.chromeSilverLow.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Sections

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ChromeSectionHeader(title: suggestionsTitle, systemImage: "sparkles")
            ForEach(suggestions) { item in
                itemRow(item, highlighted: true)
            }
        }
    }

    private var customItemRow: some View {
        Button {
            onCustom(trimmedQuery)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.chromeAmber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add \"\(trimmedQuery)\"")
                        .font(.callout.bold())
                        .foregroundStyle(.white)
                    Text("Custom / off-menu item")
                        .font(.caption)
                        .foregroundStyle(Color.chromeSilverLow)
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.chromeAmber.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.chromeAmber.opacity(0.35), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private func categorySection(name: String, items: [MenuItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ChromeSectionHeader(title: name, systemImage: "fork.knife")
            ForEach(items) { item in
                itemRow(item, highlighted: false)
            }
        }
    }

    private func itemRow(_ item: MenuItem, highlighted: Bool) -> some View {
        Button {
            onSelect(item)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.callout.bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                    if !item.description.isEmpty {
                        Text(item.description)
                            .font(.caption)
                            .foregroundStyle(Color.chromeSilverLow)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(String(format: "$%.2f", item.price))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.chromeSilverLow)
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.chromePrimary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? Color.chromePrimary.opacity(0.10) : Color.chromeSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        highlighted ? Color.chromePrimary.opacity(0.4) : Color.chromeSilverLow.opacity(0.12),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
