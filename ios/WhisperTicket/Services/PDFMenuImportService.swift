import Foundation
import PDFKit

/// Extracts menu items from a PDF file using PDFKit text extraction.
/// Heuristics: ALL-CAPS lines without a price = category headers; lines containing
/// a price pattern ($X.XX) = menu items. Items inherit the most recent header above them.
final class PDFMenuImportService: MenuImportServiceProtocol {

    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult {
        guard fileType == .pdf else {
            return .failure("PDFMenuImportService only handles PDF files.")
        }
        return await Task.detached(priority: .userInitiated) {
            self.parsePDF(at: fileURL)
        }.value
    }

    // MARK: - PDF parsing

    private func parsePDF(at url: URL) -> MenuImportResult {
        guard let document = PDFDocument(url: url) else {
            return .failure("Could not open PDF: \(url.lastPathComponent)")
        }

        var fullText = ""
        for i in 0 ..< document.pageCount {
            if let page = document.page(at: i), let pageText = page.string {
                fullText += pageText + "\n"
            }
        }

        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("PDF appears to contain no readable text (may be a scanned image).")
        }

        let restaurantName = url.deletingPathExtension().lastPathComponent
        return parseTextIntoMenu(fullText, restaurantName: restaurantName)
    }

    // MARK: - Text → MenuV1

    private func parseTextIntoMenu(_ text: String, restaurantName: String) -> MenuImportResult {
        // Price pattern: optional $ sign, digits, dot, two digits
        let priceRegex = try! NSRegularExpression(pattern: #"\$?\s*(\d{1,3}\.\d{2})"#)
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var categories: [MenuCategory] = []
        var currentCategoryName = "Menu Items"
        var currentItems: [MenuItem] = []
        var categoryIndex = 0
        var itemIndex = 0

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
                // Line has a price — treat as a menu item
                let price = extractPrice(from: line, using: priceRegex)
                let itemName = removePriceAndClean(from: line, using: priceRegex)
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
                // ALL-CAPS or title-cased short line without price = category header
                flushCategory()
                currentCategoryName = line.capitalized
            }
            // Lines that are neither a header nor have a price are skipped
            // (descriptions, page numbers, addresses, etc.)
        }
        flushCategory() // flush last category

        if categories.isEmpty {
            return .failure("Could not extract any menu items from the PDF. The format may not be supported.")
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

    // MARK: - Helpers

    private func isLikelyCategoryHeader(_ line: String) -> Bool {
        guard line.count >= 3, line.count <= 60 else { return false }
        let uppercased = line == line.uppercased()
        let titleCased = line.split(separator: " ").allSatisfy { word in
            guard let first = word.first else { return true }
            return first.isUppercase
        }
        return (uppercased || titleCased) && !line.contains("$")
    }

    private func extractPrice(from line: String, using regex: NSRegularExpression) -> Double {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let swiftRange = Range(match.range(at: 1), in: line) else { return 0 }
        return Double(line[swiftRange]) ?? 0
    }

    private func removePriceAndClean(from line: String, using regex: NSRegularExpression) -> String {
        let mutableLine = line as NSString
        let range = NSRange(location: 0, length: mutableLine.length)
        let cleaned = regex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
        return cleaned
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".-")))
    }

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
