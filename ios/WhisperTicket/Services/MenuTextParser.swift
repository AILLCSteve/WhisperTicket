import Foundation

/// Shared heuristic parser that converts free-form restaurant menu text into MenuV1.
/// Used by both PDFMenuImportService (PDFKit-extracted text) and
/// PhotoMenuImportService (Vision OCR-extracted text).
struct MenuTextParser {

    func parse(_ text: String, restaurantName: String) -> MenuImportResult {
        let priceRegex = try! NSRegularExpression(pattern: #"\$?\s*(\d{1,3}\.\d{2})"#)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var categories: [MenuCategory] = []
        var currentCategoryName = "Menu Items"
        var currentItems: [MenuItem] = []
        var categoryIndex = 0
        var itemIndex = 0
        // Accumulates lines that may be an item name appearing before the price line.
        var pendingNameLines: [String] = []

        func flushCategory() {
            guard !currentItems.isEmpty else { return }
            let catId = "cat_\(categoryIndex)"
            categories.append(MenuCategory(id: catId, name: currentCategoryName, items: currentItems))
            categoryIndex += 1
            currentItems = []
        }

        for line in lines {
            let range = NSRange(line.startIndex..., in: line)
            let priceMatches = priceRegex.matches(in: line, range: range)

            if !priceMatches.isEmpty {
                // Line contains a price — treat it as a menu item.
                let price = extractPrice(from: line, using: priceRegex)
                let inlineName = removePriceAndClean(from: line, using: priceRegex)

                // Item name: use pending lines (item name on previous line) + inline portion.
                var itemName: String
                if !inlineName.isEmpty {
                    itemName = (pendingNameLines + [inlineName]).joined(separator: " ")
                } else if !pendingNameLines.isEmpty {
                    itemName = pendingNameLines.joined(separator: " ")
                } else {
                    pendingNameLines = []
                    continue
                }
                pendingNameLines = []

                itemName = itemName
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".-")))

                guard !itemName.isEmpty else { continue }

                let item = MenuItem(
                    id: "item_\(itemIndex)",
                    name: itemName,
                    price: price,
                    description: "",
                    tags: [],
                    modifierGroups: [],
                    upsellLinks: [],
                    kitchenNoteTemplate: nil
                )
                currentItems.append(item)
                itemIndex += 1

            } else if isLikelyCategoryHeader(line) {
                pendingNameLines = []
                flushCategory()
                currentCategoryName = line.capitalized

            } else {
                // Could be an item name whose price appears on the next line,
                // a description, or noise (addresses, hours, etc.).
                if line.count <= 70 && looksLikeFoodText(line) {
                    // Only keep the FIRST food-text line as the name candidate.
                    // A second food-text line without a price is a description — ignore it
                    // so descriptions (e.g. "Classic tomato sauce, fresh mozzarella") don't
                    // get concatenated into the item name.
                    if pendingNameLines.isEmpty {
                        pendingNameLines.append(line)
                    }
                } else {
                    pendingNameLines = []
                }
            }
        }
        flushCategory()

        if categories.isEmpty {
            return .failure("Could not extract any menu items. Try a cleaner photo or a different PDF.")
        }

        let menu = MenuV1(
            restaurantId: sanitizeId(restaurantName),
            version: 1,
            currency: "USD",
            categories: categories,
            upsellRules: defaultUpsellRules()
        )
        return .success(menu)
    }

    // MARK: - Heuristics

    private func isLikelyCategoryHeader(_ line: String) -> Bool {
        guard line.count >= 3, line.count <= 60 else { return false }
        // Must not contain price-like substrings.
        guard !line.contains("$"),
              line.range(of: #"\d+\.\d{2}"#, options: .regularExpression) == nil else { return false }
        // ALL-CAPS line with at least one letter = strong signal.
        let allCaps = line == line.uppercased() && line.rangeOfCharacter(from: .letters) != nil
        // Every word starts with uppercase = title case.
        let titleCased = line.split(separator: " ").allSatisfy { word in
            guard let first = word.first else { return true }
            return first.isUppercase
        }
        return allCaps || titleCased
    }

    private func looksLikeFoodText(_ line: String) -> Bool {
        let lower = line.lowercased()
        // Skip phone numbers, URLs, hours, pure page numbers, street addresses.
        let skipPatterns = [
            #"^\d+$"#,
            #"\d{3}[-.]\d{4}"#,
            #"\b(www\.|http|\.com|@)\b"#,
            #"\b(open|closed|hours|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
            #"^\d+\s+(st|nd|rd|th|ave|street|blvd|road|drive|court|lane)\b"#,
        ]
        for pattern in skipPatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil { return false }
        }
        return true
    }

    // MARK: - Price extraction

    private func extractPrice(from line: String, using regex: NSRegularExpression) -> Double {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let swiftRange = Range(match.range(at: 1), in: line) else { return 0 }
        return Double(line[swiftRange]) ?? 0
    }

    private func removePriceAndClean(from line: String, using regex: NSRegularExpression) -> String {
        let range = NSRange(location: 0, length: (line as NSString).length)
        let cleaned = regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        return cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".-")))
    }

    // MARK: - Shared helpers

    private func sanitizeId(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private func defaultUpsellRules() -> [UpsellRule] {
        [
            UpsellRule(
                id: "rule_dessert",
                condition: UpsellCondition(hasEntree: true, hasDrink: nil),
                suggest: [UpsellSuggestion(tag: "dessert", itemId: nil)],
                playbookScript: "Save room for dessert?"
            ),
            UpsellRule(
                id: "rule_drink",
                condition: UpsellCondition(hasEntree: true, hasDrink: false),
                suggest: [UpsellSuggestion(tag: "beverage", itemId: nil)],
                playbookScript: "Can I get you something to drink with that?"
            )
        ]
    }
}
