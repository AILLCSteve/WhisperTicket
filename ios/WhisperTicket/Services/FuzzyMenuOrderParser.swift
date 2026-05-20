import Foundation

final class FuzzyMenuOrderParser: OrderParserProtocol {

    private let allergyKeywords = ["allergy", "allergic", "anaphylactic", "epipen", "cannot eat"]
    private let fillerWords = Set(["um", "uh", "like", "so", "the", "a", "an", "for"])

    // Words that look substantial but carry no food meaning — block from off-menu item names.
    private let nonFoodWords = Set([
        "lets", "let", "see", "if", "what", "how", "where", "when", "who",
        "would", "could", "should", "does", "think", "looks", "good",
        "tell", "know", "going", "really", "very", "some", "any",
        "have", "get", "more", "much", "many", "other", "same", "that",
        "this", "those", "these", "there", "then", "than", "but", "not",
        "also", "plus", "and", "want", "will", "just"
    ])

    private let temperatureMap: [String: String] = [
        "rare": "Rare", "medium rare": "Medium Rare", "med rare": "Medium Rare",
        "medium": "Medium", "med": "Medium", "medium well": "Medium Well",
        "med well": "Medium Well", "well done": "Well Done", "well": "Well Done"
    ]

    private let numberWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10
    ]

    private let negationPrefixes = ["no", "without", "hold", "remove", "skip"]

    private let courseKeywords: [String: CourseFlag] = [
        "app": .appetizer, "apps": .appetizer, "appetizer": .appetizer, "appetizers": .appetizer, "starter": .appetizer,
        "entree": .entree, "entrees": .entree, "main": .entree, "mains": .entree,
        "dessert": .dessert, "desserts": .dessert, "sweet": .dessert,
        "drink": .beverage, "drinks": .beverage, "beverage": .beverage, "beverages": .beverage,
        "side": .side, "sides": .side
    ]

    private let macroPatterns: [String: VoiceMacro] = [
        "repeat last order": .repeatLastOrder,
        "same as last time": .repeatLastOrder,
        "add side salad": .addSideSalad,
        "side salad": .addSideSalad,
        "split check": .splitCheck,
        "split the check": .splitCheck,
        "split bill": .splitCheck
    ]

    func parseDraft(transcript: String, existingDraft: TicketDraft, menu: MenuV1) -> TicketDraft {
        var draft = existingDraft
        draft.rawTranscript = transcript

        let newText: String
        if draft.consumedCursor < transcript.count {
            let startIndex = transcript.index(transcript.startIndex, offsetBy: draft.consumedCursor)
            newText = String(transcript[startIndex...])
        } else {
            return draft
        }

        let normalized = normalizeText(newText)
        let sentences = splitIntoSegments(normalized)

        var explicitCourse: CourseFlag? = nil
        var currentSeat: Int? = nil

        for sentence in sentences {
            if let course = detectCourse(in: sentence) {
                explicitCourse = course
                continue
            }
            if let seat = detectSeat(in: sentence) {
                currentSeat = seat
                continue
            }

            let allItems = menu.categories.flatMap { $0.items }
            let hasAllergy = allergyKeywords.contains { sentence.contains($0) }
            let qty = extractQuantity(from: sentence)
            let course = explicitCourse ?? .entree

            if let (matchedItem, score) = findBestItem(in: sentence, from: allItems) {
                let mods = extractModifiers(from: sentence, item: matchedItem)
                let kitchenNote = matchedItem.kitchenNoteTemplate ?? ""
                let inferredCourse = explicitCourse ?? inferCourse(from: matchedItem)

                let draftItem = DraftItem(
                    menuItemId: matchedItem.id,
                    name: matchedItem.name,
                    quantity: qty,
                    modifierNames: mods.map { $0.name },
                    negations: mods.filter { $0.isNegation }.map { $0.name },
                    course: inferredCourse,
                    seatNumber: currentSeat,
                    notes: kitchenNote,
                    confidence: score,
                    hasAllergyFlag: hasAllergy,
                    kitchenNoteTemplate: kitchenNote.isEmpty ? nil : kitchenNote
                )
                draft.addItem(draftItem)
            } else {
                // No menu match — still capture the request as an off-menu item so the
                // kitchen sees what was asked even if it is not on the current menu.
                let offMenuName = buildOffMenuName(from: sentence)
                if !offMenuName.isEmpty {
                    let draftItem = DraftItem(
                        menuItemId: "offmenu_\(UUID().uuidString)",
                        name: offMenuName,
                        quantity: qty,
                        modifierNames: [],
                        negations: [],
                        course: course,
                        seatNumber: currentSeat,
                        notes: "",
                        confidence: 0.2,
                        hasAllergyFlag: hasAllergy,
                        kitchenNoteTemplate: nil
                    )
                    draft.addItem(draftItem)
                }
            }
        }

        draft.consumedCursor = transcript.count
        return draft
    }

    func detectMacro(in text: String) -> VoiceMacro? {
        let normalized = normalizeText(text)
        for (pattern, macro) in macroPatterns {
            if normalized.contains(pattern) { return macro }
        }
        return nil
    }

    func repeatBackSummary(for draft: TicketDraft) -> String {
        guard !draft.items.isEmpty else { return "No items yet." }
        let lines = draft.items.map { item -> String in
            var line = "\(item.quantity)x \(item.name)"
            if !item.modifierNames.isEmpty {
                line += " (\(item.modifierNames.joined(separator: ", ")))"
            }
            if item.hasAllergyFlag { line += " ALLERGY" }
            return line
        }
        return "Table \(draft.tableNumber): " + lines.joined(separator: "; ")
    }

    // MARK: - Private helpers

    private func normalizeText(_ text: String) -> String {
        var result = text.lowercased()
        for filler in fillerWords {
            result = result.replacingOccurrences(of: "\\b\(filler)\\b", with: "", options: .regularExpression)
        }
        for (word, digit) in numberWords {
            result = result.replacingOccurrences(of: "\\b\(word)\\b", with: "\(digit)", options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func splitIntoSegments(_ text: String) -> [String] {
        // Replace conjunctions with segment separators so "steak and potatoes" → two items.
        let conjunctionPattern = try! NSRegularExpression(pattern: #"\b(and|plus|also|then)\b"#)
        let expanded = conjunctionPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ";"
        )
        return expanded.components(separatedBy: CharacterSet(charactersIn: ",.;:"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func detectCourse(in segment: String) -> CourseFlag? {
        for (keyword, course) in courseKeywords {
            if segment.contains(keyword) { return course }
        }
        return nil
    }

    private func detectSeat(in segment: String) -> Int? {
        let pattern = #"seat\s+(\d+)"#
        if let range = segment.range(of: pattern, options: .regularExpression) {
            let matched = String(segment[range])
            let digits = matched.filter { $0.isNumber }
            return Int(digits)
        }
        return nil
    }

    private func findBestItem(in segment: String, from items: [MenuItem]) -> (MenuItem, Double)? {
        var best: (MenuItem, Double)? = nil
        let queryTokens = segment.split(separator: " ").map(String.init)
        for item in items {
            let itemTokens = normalizeText(item.name).split(separator: " ").map(String.init)
            let score = tokenOverlapScore(query: queryTokens, candidate: itemTokens)
            if score > 0.4 {
                if best == nil || score > best!.1 { best = (item, score) }
            }
        }
        return best
    }

    /// Builds a clean, human-readable name for an off-menu item.
    /// Returns empty string if the segment is too short or is only filler/non-food words.
    private func buildOffMenuName(from segment: String) -> String {
        guard detectCourse(in: segment) == nil, detectSeat(in: segment) == nil else { return "" }
        let cleaned = TranscriptCleaner.clean(segment)
        // Require at least one word that is >3 chars, not a filler, and not a non-food verb/question word.
        let meaningful = cleaned.split(separator: " ").filter {
            let word = String($0).lowercased()
            return word.count > 3 && !fillerWords.contains(word) && !nonFoodWords.contains(word)
        }
        return meaningful.isEmpty ? "" : cleaned
    }

    private func extractQuantity(from segment: String) -> Int {
        let pattern = #"(\d+)\s+\w"#
        if let range = segment.range(of: pattern, options: .regularExpression) {
            let matched = String(segment[range])
            let digits = matched.prefix(while: { $0.isNumber })
            return Int(String(digits)) ?? 1
        }
        return 1
    }

    struct ParsedModifier {
        let name: String
        let isNegation: Bool
    }

    private func extractModifiers(from segment: String, item: MenuItem) -> [ParsedModifier] {
        var mods: [ParsedModifier] = []
        let words = segment.split(separator: " ").map(String.init)

        let sortedTemps = temperatureMap.sorted { $0.key.count > $1.key.count }
        for (phrase, label) in sortedTemps {
            if segment.contains(phrase) {
                mods.append(ParsedModifier(name: label, isNegation: false))
                break
            }
        }

        for group in item.modifierGroups {
            for modifier in group.modifiers {
                let modName = modifier.name.lowercased()
                let modTokens = modName.split(separator: " ").map(String.init)
                if tokenOverlapScore(query: words, candidate: modTokens) > 0.5 {
                    let isNegation = negationPrefixes.contains { segment.contains("\($0) " + (modTokens.first ?? "")) }
                    mods.append(ParsedModifier(name: modifier.name, isNegation: isNegation))
                }
            }
        }
        return mods
    }

    private func inferCourse(from item: MenuItem) -> CourseFlag {
        if item.tags.contains("beverage") { return .beverage }
        if item.tags.contains("dessert") { return .dessert }
        if item.tags.contains("appetizer") { return .appetizer }
        if item.tags.contains("side") { return .side }
        return .entree
    }

    private func tokenOverlapScore(query: [String], candidate: [String]) -> Double {
        let qSet = Set(query.filter { $0.count > 2 })
        let cSet = Set(candidate)
        guard !qSet.isEmpty else { return 0 }
        return Double(qSet.intersection(cSet).count) / Double(qSet.count)
    }
}
