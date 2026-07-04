import Foundation

/// Shared heuristic parser that converts free-form restaurant menu text into MenuV1.
/// Used by both PDFMenuImportService (PDFKit-extracted text) and
/// PhotoMenuImportService (Vision OCR-extracted text).
///
/// Design (validated against real Applebee's / Subway / taco-shop exports):
/// - Category headers are detected by vocabulary ("Soups and Side Salads", "SIDES")
///   or the ALL-CAPS "... MENU" suffix ("APPLEBEE'S APPETIZERS MENU"). Title-Case
///   item names can NEVER become headers just by casing.
/// - Priced documents use FIFO price/name queues, which correctly pairs both
///   column-run layouts (a block of prices followed by a block of names, spanning
///   category boundaries) and name-first layouts (name, description lines, price).
/// - Priceless documents use a name/description state machine that captures
///   wrapped description lines onto the preceding item.
/// - Aggressive noise + fine-print filtering (table headers, nav lines, page
///   footers, disclaimers, "Served with...", "A la carte.", calorie fine print).
struct MenuTextParser {

    // MARK: - Regexes & word lists

    private static let priceRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)\$?\s*(\d{1,3}\.\d{2})(?!\d)"#
    )
    private static let decimalRegex = try! NSRegularExpression(pattern: #"\d+\.\d{2}"#)

    /// Words that identify a line as a menu SECTION rather than an item.
    private static let categoryVocab: Set<String> = [
        "appetizer", "starter", "snack", "soup", "salad", "entree", "main", "steak",
        "rib", "riblet", "chicken", "pasta", "noodle", "seafood", "burger", "sandwich",
        "sub", "wrap", "taco", "burrito", "bowl", "quesadilla", "pizza", "flatbread",
        "side", "extra", "dessert", "sweet", "treat", "beverage", "drink", "kid",
        "child", "combo", "meal", "special", "favorite", "signature", "breakfast",
        "brunch", "lunch", "dinner", "wing", "sushi", "rice", "bakery", "pastry",
        "coffee", "tea", "juice", "soda", "shake", "smoothie", "float", "cocktail",
        "beer", "wine", "spirit", "liquor", "margarita", "grill", "bar", "fries",
        "slider", "hotdog", "platter", "basket", "pancake", "waffle", "omelette",
        "egg", "toast", "bagel", "muffin", "donut", "fountain", "protein",
        "favorites", "classics"
    ]

    /// Connector words ignored when testing whether every token is category vocab.
    private static let stopWords: Set<String> = [
        "and", "or", "of", "the", "from", "our", "more", "a", "an", "for", "with", "house"
    ]

    /// Structural junk — removed before parsing (both modes).
    private static let noisePatterns: [String] = [
        #"^page\s+\d+"#, #"https?://"#, #"^www\."#, #"open in app"#, #"^\d{1,3}$"#,
        #"\d{3}[.\-]\d{3}[.\-]\d{4}"#,
        #"^price$"#, #"^food\s*item$"#, #"^price\s*food\s*item$"#,
        #"menu price"#, #"price guide"#, #"^reading time"#, #"^here are"#,
        #"^contact us$"#, #"^about us$"#, #"^privacy policy"#, #"^disclaimer"#,
        #"copyright"#, "\u{00A9}", #"click here"#, #"^home\b.{0,40}menu"#,
        #"follow us"#, #"^find us"#, #"gift card"#, #"^order online"#, #"\bwebsite\b"#,
        #"^business page$"#, #"^see all\b"#, #"^photos?$"#
    ]

    /// Fine print killed in PRICED mode only (in priceless mode sentences are
    /// item descriptions and must be kept).
    private static let finePrintKeywords: [String] = [
        "served with", "a la carte", "cooked to", "consuming raw", "undercooked",
        "gratuity", "ask your server", "please ", "additional charge", "upgrade to",
        "substitut", "allerg", "for ages", "full-size", "2,000 calories",
        "nutrition", "prices may", "participation", "limited time",
        "while supplies last", "minimum of", "official website"
    ]

    /// Leading words that mark a line as descriptive prose, not an item name.
    /// NOTE: "the"/"fresh"/"crispy" deliberately absent — real items exist like
    /// "The Classic Combo", "Fresh Brewed Coffee", "Crispy Chicken Tender Salad".
    private static let descriptionStarters: [String] = [
        "a ", "an ", "made ", "served ", "our ",
        "delicious ", "topped ", "with ", "includes ", "try ", "comes "
    ]

    // MARK: - Entry point

    func parse(_ text: String, restaurantName: String) -> MenuImportResult {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { !Self.isNoiseLine($0) }

        let hasPrices = lines.contains { Self.firstPrice(in: $0) != nil }
        let categories = hasPrices
            ? parsePriced(lines: lines)
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

    // MARK: - Priced parser (FIFO price/name queues)

    private struct PendingName {
        var name: String
        var description: String = ""
    }

    private func parsePriced(lines: [String]) -> [MenuCategory] {
        var categories: [MenuCategory] = []
        var currentCategoryName = "Menu Items"
        var currentItems: [MenuItem] = []
        var categoryIndex = 0
        var itemIndex = 0
        var pendingPrices: [Double] = []
        var pendingNames: [PendingName] = []

        func makeItem(name: String, price: Double, description: String) {
            currentItems.append(MenuItem(
                id: "item_\(itemIndex)",
                name: name,
                price: price,
                description: description,
                tags: [],
                modifierGroups: [],
                upsellLinks: [],
                kitchenNoteTemplate: nil
            ))
            itemIndex += 1
        }

        func flushPendingNames() {
            // Names that never met a price become price-0 items (real for
            // mixed menus; junk-only categories are dropped at the end).
            while !pendingNames.isEmpty {
                let p = pendingNames.removeFirst()
                makeItem(name: p.name, price: 0, description: p.description)
            }
        }

        func flushCategory(newName: String) {
            flushPendingNames()
            if !currentItems.isEmpty {
                categories.append(MenuCategory(id: "cat_\(categoryIndex)", name: currentCategoryName, items: currentItems))
                categoryIndex += 1
                currentItems = []
            }
            currentCategoryName = newName
        }

        for (i, line) in lines.enumerated() {
            let price = Self.firstPrice(in: line)

            // Strong headers (ALL-CAPS ... MENU) always win. Vocab headers are only
            // honored when no prices are queued — a header never consumes a price,
            // and all-vocab item names ("Chicken Quesadilla") appear mid-block.
            var header = Self.strongHeaderName(line)
            if header == nil && pendingPrices.isEmpty {
                header = Self.vocabHeaderName(line)
                // A vocab header followed by a description line is really an item
                // name ("Pizza Sub" + ingredient list). Real headers are followed
                // by item names or prices, never ingredient prose.
                if header != nil, i + 1 < lines.count, Self.isDescriptionLike(lines[i + 1]) {
                    header = nil
                }
            }
            if let header, price == nil {
                flushCategory(newName: header)
                continue
            }

            if let price {
                let inline = Self.cleanName(Self.removePrices(from: line))
                if !pendingNames.isEmpty {
                    let p = pendingNames.removeFirst()
                    makeItem(name: p.name, price: price, description: p.description)
                } else if !inline.isEmpty, Self.pricedNameCandidate(inline) != nil {
                    makeItem(name: inline, price: price, description: "")
                } else {
                    pendingPrices.append(price)
                }
                continue
            }

            if Self.isFinePrint(line) { continue }

            if let name = Self.pricedNameCandidate(line) {
                if !pendingPrices.isEmpty {
                    makeItem(name: name, price: pendingPrices.removeFirst(), description: "")
                } else {
                    pendingNames.append(PendingName(name: name))
                }
                continue
            }

            // Description line: lowercase-leading or comma-rich text, short enough
            // to be menu copy rather than webpage disclaimer prose.
            let words = line.split(separator: " ").count
            if Self.isDescriptionLike(line) && words <= 12 {
                if !pendingNames.isEmpty {
                    if pendingNames[pendingNames.count - 1].description.count < 160 {
                        let joined = (pendingNames[pendingNames.count - 1].description + " " + line)
                            .trimmingCharacters(in: .whitespaces)
                        pendingNames[pendingNames.count - 1].description = String(joined.prefix(160))
                    }
                } else if let last = currentItems.last, last.description.count < 160 {
                    let joined = (last.description + " " + line).trimmingCharacters(in: .whitespaces)
                    currentItems[currentItems.count - 1] = MenuItem(
                        id: last.id, name: last.name, price: last.price,
                        description: String(joined.prefix(160)),
                        tags: last.tags, modifierGroups: last.modifierGroups,
                        upsellLinks: last.upsellLinks, kitchenNoteTemplate: last.kitchenNoteTemplate
                    )
                }
            }
        }
        flushPendingNames()
        if !currentItems.isEmpty {
            categories.append(MenuCategory(id: "cat_\(categoryIndex)", name: currentCategoryName, items: currentItems))
        }
        // In a priced document, a category where nothing got a price is title junk
        // ("CONDADO TACOS" queued before the first real section), not a section.
        return categories.filter { cat in cat.items.contains { $0.price > 0 } }
    }

    // MARK: - Priceless parser (name → wrapped-description state machine)

    private func parsePriceless(lines: [String]) -> [MenuCategory] {
        var categories: [MenuCategory] = []
        var currentCategoryName = "Menu Items"
        var currentItems: [MenuItem] = []
        var categoryIndex = 0
        var itemIndex = 0
        var descLineCount = 0     // lines of description consumed for the last item
        var descClosed = true     // last description line ended a sentence

        func flushCategory(newName: String) {
            if !currentItems.isEmpty {
                categories.append(MenuCategory(id: "cat_\(categoryIndex)", name: currentCategoryName, items: currentItems))
                categoryIndex += 1
                currentItems = []
            }
            currentCategoryName = newName
        }

        for (i, line) in lines.enumerated() {
            var header = Self.strongHeaderName(line) ?? Self.vocabHeaderName(line)
            if header != nil, i + 1 < lines.count, Self.isDescriptionLike(lines[i + 1]) {
                header = nil  // item name followed by its description, not a section
            }
            if let header {
                flushCategory(newName: header)
                descLineCount = 0
                descClosed = true
                continue
            }

            let candidate = Self.pricelessNameCandidate(line)
            // A name-passing line continues the description only while the current
            // description is mid-sentence and short (wrapped PDF lines).
            let startsNewItem = candidate != nil
                && (descClosed || descLineCount == 0 || descLineCount >= 3)
            if let candidate, startsNewItem {
                currentItems.append(MenuItem(
                    id: "item_\(itemIndex)", name: candidate, price: 0, description: "",
                    tags: [], modifierGroups: [], upsellLinks: [], kitchenNoteTemplate: nil
                ))
                itemIndex += 1
                descLineCount = 0
                descClosed = false
                continue
            }

            // Description / wrapped continuation for the last item.
            if let last = currentItems.last {
                if last.description.count < 160 {
                    let joined = (last.description + " " + line).trimmingCharacters(in: .whitespaces)
                    currentItems[currentItems.count - 1] = MenuItem(
                        id: last.id, name: last.name, price: last.price,
                        description: String(joined.prefix(160)),
                        tags: last.tags, modifierGroups: last.modifierGroups,
                        upsellLinks: last.upsellLinks, kitchenNoteTemplate: last.kitchenNoteTemplate
                    )
                }
                descLineCount += 1
                descClosed = Self.endsSentence(line)
            }
            // else: stray pre-header text — drop.
        }
        flushCategory(newName: "")
        return categories
    }

    // MARK: - Line classification

    private static func isNoiseLine(_ line: String) -> Bool {
        if line.contains("|") { return true }  // "Appetizers | Soups | ..." nav rows
        let lower = line.lowercased()
        for pattern in noisePatterns {
            if lower.range(of: pattern, options: .regularExpression) != nil { return true }
        }
        // Title junk: a short line containing the bare word "menu" that is not
        // itself a category header ("Subway Menu", "Menu for Subway").
        if lower.range(of: #"\bmenu\b"#, options: .regularExpression) != nil,
           line.split(separator: " ").count <= 6,
           strongHeaderName(line) == nil, vocabHeaderName(line) == nil {
            return true
        }
        return false
    }

    private static func isFinePrint(_ line: String) -> Bool {
        let lower = line.lowercased()
        return finePrintKeywords.contains { lower.contains($0) }
    }

    /// An ingredient/description line: lowercase-leading or comma-rich.
    private static func isDescriptionLike(_ line: String) -> Bool {
        if let first = line.first, first.isLowercase { return true }
        return line.filter { $0 == "," }.count >= 2
    }

    private static func endsSentence(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " -\u{2013}\u{2014}*\"'"))
        return trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")
    }

    // MARK: - Header detection

    /// Drops a single leading possessive brand token ("APPLEBEE'S", "JOE'S").
    private static func stripBrand(_ words: [String]) -> [String] {
        guard words.count > 1 else { return words }
        let first = words[0].lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return first.hasSuffix("'s") ? Array(words.dropFirst()) : words
    }

    /// Rule (a): ALL-CAPS line ending in "MENU" — always a header.
    private static func strongHeaderName(_ line: String) -> String? {
        guard line.count >= 3, line.count <= 60 else { return nil }
        guard !containsDecimalPrice(line) else { return nil }
        guard line == line.uppercased(), line.rangeOfCharacter(from: .letters) != nil else { return nil }
        let words = stripBrand(line.split(separator: " ").map(String.init))
        guard words.count >= 2, words.last?.uppercased() == "MENU" else { return nil }
        let core = words.dropLast().joined(separator: " ")
        return capitalizedWords(core)
    }

    /// Rule (b): every meaningful token is category vocabulary
    /// ("Soups and Side Salads", "SIDES", "Snacks & Sides").
    private static func vocabHeaderName(_ line: String) -> String? {
        guard line.count >= 3, line.count <= 60 else { return nil }
        guard !containsDecimalPrice(line) else { return nil }
        guard line.rangeOfCharacter(from: .letters) != nil else { return nil }
        let words = stripBrand(line.split(separator: " ").map(String.init))
        guard !words.isEmpty else { return nil }
        let toks = tokenize(words.joined(separator: " "))
            .filter { !stopWords.contains($0) && Int($0) == nil }
        guard !toks.isEmpty, toks.count <= 4, toks.allSatisfy({ isVocabWord($0) }) else { return nil }
        var name = words.joined(separator: " ")
        if let lastWord = name.split(separator: " ").last, lastWord.lowercased() == "menu" {
            name = name.split(separator: " ").dropLast().joined(separator: " ")
        }
        return line == line.uppercased() ? capitalizedWords(name) : name
    }

    private static func containsDecimalPrice(_ line: String) -> Bool {
        let range = NSRange(line.startIndex..., in: line)
        return decimalRegex.firstMatch(in: line, range: range) != nil
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    private static func isVocabWord(_ token: String) -> Bool {
        var t = token
        if t.hasSuffix("'s") { t = String(t.dropLast(2)) }
        if categoryVocab.contains(t) { return true }
        if t.hasSuffix("es"), categoryVocab.contains(String(t.dropLast(2))) { return true }
        if t.hasSuffix("s"), categoryVocab.contains(String(t.dropLast())) { return true }
        return false
    }

    private static func capitalizedWords(_ s: String) -> String {
        s.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    // MARK: - Item-name candidates

    /// Priced mode: 1–10 words, starts with an uppercase letter or digit, not
    /// descriptive prose, not a trailing sentence.
    private static func pricedNameCandidate(_ line: String) -> String? {
        nameCandidate(line, maxWords: 10)
    }

    /// Priceless mode is stricter (long lines are descriptions).
    private static func pricelessNameCandidate(_ line: String) -> String? {
        nameCandidate(line, maxWords: 6)
    }

    private static func nameCandidate(_ line: String, maxWords: Int) -> String? {
        let words = line.split(separator: " ")
        guard (1...maxWords).contains(words.count), line.count <= 70 else { return nil }
        let stripped = line.drop { $0 == "\"" || $0 == "'" }
        guard let first = stripped.first, first.isUppercase || first.isNumber else { return nil }
        let lower = line.lowercased()
        for starter in descriptionStarters where lower.hasPrefix(starter) { return nil }
        guard line.filter({ $0 == "," }).count <= 1 else { return nil }
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: " -\u{2013}\u{2014}*"))
        if (trimmed.hasSuffix(".") || trimmed.hasSuffix("!") || trimmed.hasSuffix("?")),
           words.count > 2,
           trimmed.range(of: #"\b[A-Z]\.$"#, options: .regularExpression) == nil {
            return nil  // sentence, not a name ("2 full-size entrees.") — but keep "B.M.T."
        }
        let cleaned = cleanName(line)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func cleanName(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00AE}", with: "")   // registered mark
            .replacingOccurrences(of: "\u{2122}", with: "")  // trademark
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t-\u{2013}\u{2014}*,."))
    }

    // MARK: - Price extraction

    private static func firstPrice(in line: String) -> Double? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = priceRegex.firstMatch(in: line, range: range),
              let swiftRange = Range(match.range(at: 1), in: line) else { return nil }
        return Double(line[swiftRange])
    }

    private static func removePrices(from line: String) -> String {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return priceRegex.stringByReplacingMatches(in: line, range: range, withTemplate: "")
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
