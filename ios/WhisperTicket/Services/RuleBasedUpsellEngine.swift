import Foundation

final class RuleBasedUpsellEngine: UpsellEngineProtocol {
    func suggestions(for draft: TicketDraft, menu: MenuV1) -> [UpsellSuggestionResult] {
        var results: [UpsellSuggestionResult] = []

        let hasEntree = draft.items.contains { $0.course == .entree }
        let hasDrink = draft.items.contains { $0.course == .beverage }
        let allItems = menu.categories.flatMap { $0.items }
        let draftItemIds = Set(draft.items.map { $0.menuItemId })

        for rule in menu.upsellRules {
            var conditionMet = true
            if let requiresEntree = rule.condition.hasEntree {
                conditionMet = conditionMet && (hasEntree == requiresEntree)
            }
            if let requiresNoDrink = rule.condition.hasDrink {
                conditionMet = conditionMet && (hasDrink == requiresNoDrink)
            }
            guard conditionMet else { continue }

            for suggestion in rule.suggest {
                var candidates: [MenuItem] = []
                if let tag = suggestion.tag {
                    candidates = allItems.filter { $0.tags.contains(tag) }
                } else if let itemId = suggestion.itemId {
                    candidates = allItems.filter { $0.id == itemId }
                }

                for candidate in candidates.prefix(2) {
                    guard !draftItemIds.contains(candidate.id) else { continue }
                    results.append(UpsellSuggestionResult(
                        menuItem: candidate,
                        reason: "Suggested pairing",
                        playbookScript: rule.playbookScript
                    ))
                }
            }
        }

        // Deduplicate by item ID
        var seen = Set<String>()
        return results.filter { seen.insert($0.menuItem.id).inserted }
    }
}
