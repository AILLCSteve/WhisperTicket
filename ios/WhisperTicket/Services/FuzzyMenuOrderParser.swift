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

    // Units + teens (each maps to its own value), tens (multiples of 10), and
    // words like "dozen"/"couple". Used by the compound quantity parser so
    // "forty five coffees" → 45, not 1. Kept separate from the segment normalizer
    // so we can accumulate compounds ("forty" + "five") instead of substituting
    // each word independently.
    private let numberUnits: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
        "dozen": 12, "couple": 2, "pair": 2
    ]

    private let numberTens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90
    ]

    // Short grammatical words that carry no matching signal. Removed from the
    // query token set so item selection keys on real food words only.
    private let stopWords = Set([
        "and", "the", "with", "for", "a", "an", "of", "or", "some", "please",
        "get", "have", "want", "would", "like", "can", "could", "i", "we",
        "me", "us", "my", "our", "to", "on", "in", "add", "also", "plus",
        "then", "just", "that", "this", "it", "is", "are", "be", "no"
    ])

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

            let candidates = rankItems(in: sentence, from: allItems)
            if let top = candidates.first {
                let matchedItem = top.item
                let mods = extractModifiers(from: sentence, item: matchedItem)
                let kitchenNote = matchedItem.kitchenNoteTemplate ?? ""
                let inferredCourse = explicitCourse ?? inferCourse(from: matchedItem)

                // Ambiguous when a runner-up scores nearly as high — i.e. the speech
                // didn't contain enough clues to separate them. Surface the top few
                // (including the guess) for one-tap confirmation instead of silently
                // committing a coin-flip.
                let contenders = candidates.dropFirst().filter { top.score - $0.score <= 0.12 }
                let alternatives: [String] = contenders.isEmpty
                    ? []
                    : Array(([matchedItem.id] + contenders.map { $0.item.id }).prefix(4))

                let draftItem = DraftItem(
                    menuItemId: matchedItem.id,
                    name: matchedItem.name,
                    quantity: qty,
                    modifierNames: mods.map { $0.name },
                    negations: mods.filter { $0.isNegation }.map { $0.name },
                    course: inferredCourse,
                    seatNumber: currentSeat,
                    notes: kitchenNote,
                    confidence: alternatives.isEmpty ? top.score : min(top.score, 0.5),
                    hasAllergyFlag: hasAllergy,
                    kitchenNoteTemplate: kitchenNote.isEmpty ? nil : kitchenNote,
                    alternativeMenuItemIds: alternatives
                )
                draft.addItem(draftItem)
            } else {
                // No menu match — still capture the request as an off-menu item so the
                // kitchen sees what was asked even if it is not on the current menu.
                let offMenuName = buildOffMenuName(from: sentence)
                if !offMenuName.isEmpty {
                    // Deterministic id (by normalized name) so a full-transcript
                    // reparse dedups the same off-menu request instead of adding a
                    // fresh random-UUID copy each time.
                    let offMenuSlug = offMenuName.lowercased().replacingOccurrences(of: " ", with: "_")
                    let draftItem = DraftItem(
                        menuItemId: "offmenu_\(offMenuSlug)",
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
        // Convert only standalone units/teens to digits (one→1 … nineteen→19) so
        // "seat three" and simple counts work. Tens words ("forty") are LEFT as
        // words and combined by extractQuantity so compounds ("forty five" → 45)
        // aren't broken into "40 5".
        for (word, digit) in numberUnits {
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

    struct ItemMatch {
        let item: MenuItem
        let score: Double        // combined query- + item-coverage
        let queryCoverage: Double
    }

    /// Ranks menu items against a spoken segment. Score rewards BOTH how much of
    /// the query an item explains (queryCoverage) and how completely the item's own
    /// name is present (itemCoverage) — so when the speaker adds clues ("ham and
    /// cheese"), the item whose full name is matched wins, but a bare "ham" leaves
    /// two sandwiches tied (→ disambiguation) instead of arbitrarily picking one.
    private func rankItems(in segment: String, from items: [MenuItem]) -> [ItemMatch] {
        let qTokens = contentTokens(segment)
        let qSet = Set(qTokens)
        guard !qSet.isEmpty else { return [] }

        var matches: [ItemMatch] = []
        for item in items {
            let cTokens = contentTokens(normalizeText(item.name))
            let cSet = Set(cTokens)
            guard !cSet.isEmpty else { continue }
            let overlap = qSet.intersection(cSet).count
            guard overlap > 0 else { continue }
            let queryCoverage = Double(overlap) / Double(qSet.count)
            let itemCoverage = Double(overlap) / Double(cSet.count)
            // Require at least half the item's name OR a strong slice of the query
            // to be present — blocks "chicken" from matching "Chicken Caesar Wrap"
            // on one shared token while allowing intended single-word items.
            guard itemCoverage >= 0.5 || queryCoverage >= 0.5 else { continue }
            let score = 0.6 * queryCoverage + 0.4 * itemCoverage
            matches.append(ItemMatch(item: item, score: score, queryCoverage: queryCoverage))
        }
        return matches.sorted { $0.score > $1.score }
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

    /// Extracts a leading quantity from a segment, understanding digits AND spoken
    /// number words including compounds: "45 coffees" → 45, "forty five" → 45,
    /// "a dozen wings" → 12, "twenty two" → 22. Returns 1 when no count is present.
    private func extractQuantity(from segment: String) -> Int {
        let tokens = segment.split(separator: " ").map(String.init)
        // Find the first run of number tokens (digit or number word) and evaluate it.
        var run: [String] = []
        var started = false
        for token in tokens {
            if isNumberToken(token) {
                run.append(token)
                started = true
            } else if started {
                break   // run ended; take the first count only
            }
        }
        let value = evaluateNumberRun(run)
        return value > 0 ? value : 1
    }

    private func isNumberToken(_ token: String) -> Bool {
        if token.allSatisfy({ $0.isNumber }) && !token.isEmpty { return true }
        return numberUnits[token] != nil || numberTens[token] != nil || token == "hundred"
    }

    /// Accumulates a run of number tokens the way English is spoken:
    /// tens + units add ("forty" 40 + "five" 5 = 45), "hundred" multiplies.
    private func evaluateNumberRun(_ run: [String]) -> Int {
        guard !run.isEmpty else { return 0 }
        var total = 0
        var current = 0
        for token in run {
            if let digits = Int(token) {
                current += digits
            } else if let tens = numberTens[token] {
                current += tens
            } else if let unit = numberUnits[token] {
                current += unit
            } else if token == "hundred" {
                current = max(1, current) * 100
            }
        }
        total += current
        return total
    }

    /// Crude singular stem so plural speech matches singular menu names
    /// ("coffees" → "coffee", "wings" → "wing", "sandwiches" → "sandwich").
    private func singularize(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("es"), word.hasSuffix("ches") || word.hasSuffix("shes") || word.hasSuffix("ses") || word.hasSuffix("xes") {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }

    /// Real food-signal tokens from a query: split, drop stopwords and pure
    /// numbers, singularize what remains.
    private func contentTokens(_ text: String) -> [String] {
        text.split(separator: " ")
            .map { singularize(String($0)) }
            .filter { $0.count > 1 && !stopWords.contains($0) && !$0.allSatisfy(\.isNumber) }
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
        let qSet = Set(query.map { singularize($0) }.filter { $0.count > 2 })
        let cSet = Set(candidate.map { singularize($0) })
        guard !qSet.isEmpty else { return 0 }
        return Double(qSet.intersection(cSet).count) / Double(qSet.count)
    }
}
