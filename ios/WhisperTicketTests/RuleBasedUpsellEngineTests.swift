import XCTest
@testable import WhisperTicket

final class RuleBasedUpsellEngineTests: XCTestCase {

    private let engine = RuleBasedUpsellEngine()

    // MARK: - Fixtures

    private func makeDessertItem() -> MenuItem {
        MenuItem(id: "cake1", name: "Chocolate Cake", price: 8.0,
                 description: "", tags: ["dessert"], modifierGroups: [], upsellLinks: [])
    }

    private func makeBeverageItem() -> MenuItem {
        MenuItem(id: "cola1", name: "Cola", price: 3.0,
                 description: "", tags: ["beverage"], modifierGroups: [], upsellLinks: [])
    }

    private func makeEntreeDraftItem(menuItemId: String = "steak1") -> DraftItem {
        DraftItem(menuItemId: menuItemId, name: "Steak", quantity: 1,
                  modifierNames: [], negations: [], course: .entree,
                  seatNumber: 1, notes: "", confidence: 1.0, hasAllergyFlag: false)
    }

    private func makeBeverageDraftItem() -> DraftItem {
        DraftItem(menuItemId: "cola1", name: "Cola", quantity: 1,
                  modifierNames: [], negations: [], course: .beverage,
                  seatNumber: 1, notes: "", confidence: 1.0, hasAllergyFlag: false)
    }

    private func makeMenu(with extraItems: [MenuItem] = []) -> MenuV1 {
        let allItems = [makeDessertItem(), makeBeverageItem()] + extraItems
        let category = MenuCategory(id: "cat1", name: "All", items: allItems)
        let rules = [
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
                playbookScript: "Can I get you something to drink?"
            )
        ]
        return MenuV1(restaurantId: "test", version: 1, currency: "USD",
                      categories: [category], upsellRules: rules)
    }

    // MARK: - Tests

    func test_noSuggestions_whenDraftIsEmpty() {
        let draft = TicketDraft(tableNumber: "1")
        let results = engine.suggestions(for: draft, menu: makeMenu())
        XCTAssertTrue(results.isEmpty)
    }

    func test_dessertSuggested_whenEntreeOrdered() {
        var draft = TicketDraft(tableNumber: "1")
        draft.addItem(makeEntreeDraftItem())
        let results = engine.suggestions(for: draft, menu: makeMenu())
        let ids = results.map { $0.menuItem.id }
        XCTAssertTrue(ids.contains("cake1"), "Dessert should be suggested when entree is ordered. Got: \(ids)")
    }

    func test_beverageSuggested_whenEntreeOrderedWithNoDrink() {
        var draft = TicketDraft(tableNumber: "1")
        draft.addItem(makeEntreeDraftItem())
        let results = engine.suggestions(for: draft, menu: makeMenu())
        let ids = results.map { $0.menuItem.id }
        XCTAssertTrue(ids.contains("cola1"), "Beverage should be suggested when entree ordered and no drink. Got: \(ids)")
    }

    func test_beverageNotSuggested_whenDrinkAlreadyOrdered() {
        var draft = TicketDraft(tableNumber: "1")
        draft.addItem(makeEntreeDraftItem())
        draft.addItem(makeBeverageDraftItem())
        let results = engine.suggestions(for: draft, menu: makeMenu())
        let ids = results.map { $0.menuItem.id }
        XCTAssertFalse(ids.contains("cola1"), "Beverage should NOT be suggested when drink already ordered. Got: \(ids)")
    }

    func test_alreadyOrderedItemNotSuggested() {
        let cake = makeDessertItem()
        var draft = TicketDraft(tableNumber: "1")
        draft.addItem(makeEntreeDraftItem())
        draft.addItem(DraftItem(menuItemId: cake.id, name: cake.name, quantity: 1,
                                modifierNames: [], negations: [], course: .dessert,
                                seatNumber: 1, notes: "", confidence: 1.0, hasAllergyFlag: false))
        let results = engine.suggestions(for: draft, menu: makeMenu())
        let ids = results.map { $0.menuItem.id }
        XCTAssertFalse(ids.contains("cake1"), "Already-ordered item must not be suggested again")
    }

    func test_noSuggestions_forEmptyTagsMenuItems() {
        // Tag-based upsell should return zero candidates when all menu items have empty tags
        let itemNoTags = MenuItem(id: "x1", name: "Mystery Item", price: 5.0,
                                  description: "", tags: [], modifierGroups: [], upsellLinks: [])
        let category = MenuCategory(id: "cat1", name: "All", items: [itemNoTags])
        let rules = [
            UpsellRule(id: "rule_dessert",
                       condition: UpsellCondition(hasEntree: true, hasDrink: nil),
                       suggest: [UpsellSuggestion(tag: "dessert", itemId: nil)],
                       playbookScript: nil)
        ]
        let menu = MenuV1(restaurantId: "test", version: 1, currency: "USD",
                          categories: [category], upsellRules: rules)
        var draft = TicketDraft(tableNumber: "1")
        draft.addItem(makeEntreeDraftItem())
        let results = engine.suggestions(for: draft, menu: menu)
        XCTAssertTrue(results.isEmpty,
                      "No suggestions should fire when all menu items have empty tags (imported menu scenario)")
    }

    func test_deduplicationPreventsRepeatSuggestions() {
        // Two rules that would suggest the same item
        let cake = makeDessertItem()
        let category = MenuCategory(id: "cat1", name: "All", items: [cake])
        let rules = [
            UpsellRule(id: "r1", condition: UpsellCondition(hasEntree: true, hasDrink: nil),
                       suggest: [UpsellSuggestion(tag: "dessert", itemId: nil)], playbookScript: nil),
            UpsellRule(id: "r2", condition: UpsellCondition(hasEntree: true, hasDrink: nil),
                       suggest: [UpsellSuggestion(tag: "dessert", itemId: nil)], playbookScript: nil)
        ]
        let menu = MenuV1(restaurantId: "test", version: 1, currency: "USD",
                          categories: [category], upsellRules: rules)
        var draft = TicketDraft(tableNumber: "1")
        draft.addItem(makeEntreeDraftItem())
        let results = engine.suggestions(for: draft, menu: menu)
        let cakeResults = results.filter { $0.menuItem.id == "cake1" }
        XCTAssertEqual(cakeResults.count, 1, "Same item should not appear twice in suggestions")
    }

    func test_playbookScript_isIncludedInResult() {
        var draft = TicketDraft(tableNumber: "1")
        draft.addItem(makeEntreeDraftItem())
        let results = engine.suggestions(for: draft, menu: makeMenu())
        let dessertResult = results.first { $0.menuItem.id == "cake1" }
        XCTAssertEqual(dessertResult?.playbookScript, "Save room for dessert?")
    }
}
