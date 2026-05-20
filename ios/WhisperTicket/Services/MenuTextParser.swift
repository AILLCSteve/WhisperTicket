import Foundation

/// Shared heuristic parser that converts free-form restaurant menu text into MenuV1.
/// Used by both PDFMenuImportService (PDFKit-extracted text) and
/// PhotoMenuImportService (Vision OCR-extracted text).
struct MenuTextParser {

    func parse(_ text: String, restaurantName: String) -> MenuImportResult {
        // Looser price regex — no leading dollar sign required (handles "4.68 taco" format)
        let priceRegex = try! NSRegularExpression(
            pattern: #"(?<!\d)\$?\s*(\d{1,3}\.\d{2})(?!\d)"#
        )
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !isNoiseLine($0) }

        // Choose parser based on whether any prices exist in the document.
        let hasPrices = lines.contains { line in
            let r = NSRange(line.startIndex..., in: line)
            return priceRegex.firstMatch(in: line, range: r) != nil
        }

        let categories = hasPrices
            ? parsePriced(lines: lines, priceRegex: priceRegex)
            : parsePriceless(lines: lines)

        if categories.isEmpty {
            return .failure("Could not extract any menu items. Try a cleaner photo or a different file.")
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

    // MARK: - Priced menu parser

    /// Parses menus that contain explicit prices. Uses look-ahead to distinguish
    /// item names from category headers when the line is ambiguous (e.g. ALL-CAPS
    /// item names that would otherwise be misclassified as section headers).
    private func parsePriced(lines: [String], priceRegex: NSRegularExpression) -> [MenuCategory] {
        var categories: [MenuCategory] = []
        var currentCategoryName = "Menu Items"
        var currentItems: [MenuItem] = []
        var categoryIndex = 0
        var itemIndex = 0
        var pendingNameLines: [String] = []

        func flushCategory() {
            guard !currentItems.isEmpty else { return }
            categories.append(MenuCategory(id: "cat_\(categoryIndex)", name: currentCategoryName, items: currentItems))
            categoryIndex += 1
            currentItems = []
        }

        for (i, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..., in: line)
            let priceMatches = priceRegex.matches(in: line, range: range)

            if !priceMatches.isEmpty {
                // Price line: build item from pending name(s) + any inline text.
                let price = extractPrice(from: line, using: priceRegex)
                let inlineName = removePriceAndClean(from: line, using: priceRegex)

                var itemName: String
                if !pendingNameLines.isEmpty {
                    // Prefer the dedicated name line(s); inline remainder from price line
                    // is often a category label ("taco", "burrito") and is dropped.
                    itemName = pendingNameLines.joined(separator: " ")
                } else if !inlineName.isEmpty {
                    itemName = inlineName
                } else {
                    pendingNameLines = []
                    continue
                }
                pendingNameLines = []

                itemName = itemName
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".-")))
                guard !itemName.isEmpty else { continue }

                currentItems.append(MenuItem(
                    id: "item_\(itemIndex)",
                    name: itemName,
                    price: price,
                    description: "",
                    tags: [],
                    modifierGroups: [],
                    upsellLinks: [],
                    kitchenNoteTemplate: nil
                ))
                itemIndex += 1

            } else if isLikelyCategoryHeader(line) {
                // Look ahead: if a price exists within 3 lines, this is an item name
                // (e.g. ALL-CAPS "CHICKEN BACON RANCH" followed by "4.68"), not a section header.
                if priceExistsAhead(in: lines, from: i, within: 3, using: priceRegex) {
                    if pendingNameLines.isEmpty { pendingNameLines.append(line) }
                } else {
                    pendingNameLines = []
                    flushCategory()
                    currentCategoryName = normalizeCategoryName(line)
                }

            } else if looksLikeFoodText(line) && line.count <= 70 {
                // Only keep the first food-text line as the pending item name.
                // A second food-text line without a price is a description — skip it.
                if pendingNameLines.isEmpty { pendingNameLines.append(line) }

            } else {
                pendingNameLines = []
            }
        }
        flushCategory()
        return categories
    }

    /// Returns true if any of the next `n` lines (after `index`) contains a price.
    private func priceExistsAhead(
        in lines: [String], from index: Int, within n: Int,
        using regex: NSRegularExpression
    ) -> Bool {
        let end = min(lines.count, index + 1 + n)
        for j in (index + 1)..<end {
            let r = NSRange(lines[j].startIndex..., in: lines[j])
            if regex.firstMatch(in: lines[j], range: r) != nil { return true }
        }
        return false
    }

    // MARK: - Priceless menu parser (Yelp / photo-only menus)

    /// Parses menus with NO prices (e.g. Yelp PDFs that list names and descriptions only).
    /// Extracts item names based on position after section headers and line characteristics.
    private func parsePriceless(lines: [String]) -> [MenuCategory] {
        var categories: [MenuCategory] = []
        var currentCategoryName = "Menu Items"
        var currentItems: [MenuItem] = []
        var categoryIndex = 0
        var itemIndex = 0
        // After an item name is captured, the next food-text line is a description — skip it.
        var lastWasItemName = false

        func flushCategory() {
            guard !currentItems.isEmpty else { return }
            categories.append(MenuCategory(id: "cat_\(categoryIndex)", name: currentCategoryName, items: currentItems))
            categoryIndex += 1
            currentItems = []
        }

        for line in lines {
            if isLikelyCategoryHeader(line) {
                lastWasItemName = false
                flushCategory()
                currentCategoryName = normalizeCategoryName(line)
                continue
            }
            guard looksLikeFoodText(line) else {
                lastWasItemName = false
                continue
            }
            if looksLikePricelessItemName(line) && !lastWasItemName {
                let name = line
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
                currentItems.append(MenuItem(
                    id: "item_\(itemIndex)",
                    name: name,
                    price: 0,
                    description: "",
                    tags: [],
                    modifierGroups: [],
                    upsellLinks: [],
                    kitchenNoteTemplate: nil
                ))
                itemIndex += 1
                lastWasItemName = true
            } else {
                // Description line or second candidate after an item — skip.
                lastWasItemName = false
            }
        }
        flushCategory()
        return categories
    }

    // MARK: - Heuristics

    private func isNoiseLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let noisePatterns: [String] = [
            #"^page\s+\d+"#,             // "Page 3 of 25"
            #"^https?://"#,              // URLs
            #"^www\."#,                  // URLs without scheme
            #"open in app"#,             // Yelp prompt
            #"^\d{1,3}$"#,              // bare page numbers
            #"\d{3}[.\-]\d{3}[.\-]\d{4}"#,   // phone numbers
        ]
        for pattern in noisePatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        return false
    }

    private func isLikelyCategoryHeader(_ line: String) -> Bool {
        guard line.count >= 3, line.count <= 60 else { return false }
        guard !line.contains("$"),
              line.range(of: #"\d+\.\d{2}"#, options: .regularExpression) == nil else { return false }

        let words = line.split(separator: " ")

        // ALL-CAPS qualifies as a header only when short (1-2 words).
        // 3+ word ALL-CAPS phrases (e.g. "CHICKEN BACON RANCH") are item names.
        let allCaps = line == line.uppercased()
            && line.rangeOfCharacter(from: .letters) != nil
            && words.count <= 2

        // Proper Title Case: every word starts with uppercase AND contains at least one
        // lowercase letter (so pure ALL-CAPS words like "CHICKEN" are excluded).
        let titleCased = !allCaps && words.allSatisfy { word in
            let w = String(word)
            guard let first = w.first, first.isUppercase else { return false }
            // Single-char words (abbreviations like "A") are fine.
            return w.count == 1 || w.dropFirst().contains { $0.isLowercase }
        }

        return allCaps || titleCased
    }

    private func looksLikeFoodText(_ line: String) -> Bool {
        let lower = line.lowercased()
        let skipPatterns: [String] = [
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

    /// Heuristic for priceless menus: is this line a standalone item name rather than a description?
    private func looksLikePricelessItemName(_ line: String) -> Bool {
        let words = line.split(separator: " ")
        // Item names are short; long lines are descriptions.
        guard words.count >= 1, words.count <= 6 else { return false }
        // Must start with a capital letter.
        guard let first = line.first, first.isUppercase else { return false }
        // Descriptions commonly start with articles or sentence-leading words.
        let lower = line.lowercased()
        let descriptionStarters = [
            "a ", "an ", "the ", "made ", "served ", "our ", "fresh ",
            "crispy ", "delicious ", "topped ", "with ", "includes ", "try "
        ]
        for starter in descriptionStarters where lower.hasPrefix(starter) { return false }
        // Too many commas signals a list / description.
        guard line.filter({ $0 == "," }).count <= 1 else { return false }
        // Sentence-ending period after multiple words = description sentence.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(".") && words.count > 2 { return false }
        if trimmed.hasSuffix("!") || trimmed.hasSuffix("?") { return false }
        return true
    }

    private func normalizeCategoryName(_ line: String) -> String {
        line == line.uppercased() ? line.capitalized : line
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
