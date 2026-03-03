import Foundation

final class FuzzyMenuOrderParser: OrderParserProtocol {

    private let allergyKeywords = ["allergy", "allergic", "anaphylactic", "epipen", "cannot eat"]
    private let fillerWords = Set(["um", "uh", "like", "so", "and", "the", "a", "an", "for"])

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

        var currentCourse: CourseFlag = .entree
        var currentSeat: Int? = nil

        for sentence in sentences {
            if let course = detectCourse(in: sentence) {
                currentCourse = course
                continue
            }
            if let seat = detectSeat(in: sentence) {
                currentSeat = seat
                continue
            }

            let allItems = menu.categories.flatMap { $0.items }
            if let (matchedItem, score) = findBestItem(in: sentence, from: allItems) {
                let qty = extractQuantity(from: sentence)
                let mods = extractModifiers(from: sentence, item: matchedItem)
                let hasAllergy = allergyKeywords.contains { sentence.contains($0) }
                let kitchenNote = matchedItem.kitchenNoteTemplate ?? ""

                let draftItem = DraftItem(
                    menuItemId: matchedItem.id,
                    name: matchedItem.name,
                    quantity: qty,
                    modifierNames: mods.map { $0.name },
                    negations: mods.filter { $0.isNegation }.map { $0.name },
                    course: currentCourse,
                    seatNumber: currentSeat,
                    notes: kitchenNote,
                    confidence: score,
                    hasAllergyFlag: hasAllergy,
                    kitchenNoteTemplate: kitchenNote.isEmpty ? nil : kitchenNote
                )
                draft.addItem(draftItem)
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
            if item.hasAllergyFlag { line += " ⚠️ ALLERGY" }
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
        text.components(separatedBy: CharacterSet(charactersIn: ",."))
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

    private func extractQuantity(from segment: String) -> Int {
        // Match digits anywhere in the segment (not just at start)
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

        // Detect temperature (check multi-word phrases first)
        let sortedTemps = temperatureMap.sorted { $0.key.count > $1.key.count }
        for (phrase, label) in sortedTemps {
            if segment.contains(phrase) {
                mods.append(ParsedModifier(name: label, isNegation: false))
                break
            }
        }

        // Detect modifier options from groups
        for group in item.modifierGroups {
            for modifier in group.modifiers {
                let modName = modifier.name.lowercased()
                let modTokens = modName.split(separator: " ").map(String.init)
                if tokenOverlapScore(query: words, candidate: modTokens) > 0.5 {
                    let isNegation = negationPrefixes.contains { segment.contains("\($0) " + (modTokens.first ?? "")) }
                    mods.append(ParsedModifier(
                        name: isNegation ? "No \(modifier.name)" : modifier.name,
                        isNegation: isNegation
                    ))
                }
            }
        }
        return mods
    }

    private func tokenOverlapScore(query: [String], candidate: [String]) -> Double {
        let qSet = Set(query.filter { $0.count > 2 })
        let cSet = Set(candidate)
        guard !qSet.isEmpty else { return 0 }
        return Double(qSet.intersection(cSet).count) / Double(qSet.count)
    }
}
