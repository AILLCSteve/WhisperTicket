import XCTest
@testable import WhisperTicket

final class FuzzyMenuOrderParserTests: XCTestCase {

    // MARK: - Fixtures

    private let parser = FuzzyMenuOrderParser()

    private func makeMenu(items: [(id: String, name: String, tags: [String], modifiers: [(id: String, name: String)] = [])]) -> MenuV1 {
        let menuItems = items.map { i in
            MenuItem(
                id: i.id,
                name: i.name,
                price: 10.0,
                description: "",
                tags: i.tags,
                modifierGroups: i.modifiers.isEmpty ? [] : [
                    ModifierGroup(id: "mg_\(i.id)", name: "Options", required: false, maxSelect: 1,
                                  modifiers: i.modifiers.map { ModifierOption(id: $0.id, name: $0.name, priceDelta: 0) })
                ],
                upsellLinks: []
            )
        }
        return MenuV1(
            restaurantId: "test",
            version: 1,
            currency: "USD",
            categories: [MenuCategory(id: "cat1", name: "All", items: menuItems)],
            upsellRules: []
        )
    }

    private func makeDraft() -> TicketDraft {
        TicketDraft(tableNumber: "1")
    }

    // MARK: - Basic item matching

    func test_parseDraft_findsExactItemByName() {
        let menu = makeMenu(items: [("b1", "Cheeseburger", [])])
        let draft = parser.parseDraft(transcript: "cheeseburger", existingDraft: makeDraft(), menu: menu)
        XCTAssertEqual(draft.items.count, 1)
        XCTAssertEqual(draft.items.first?.name, "Cheeseburger")
    }

    func test_parseDraft_findsItemByPartialTokenMatch() {
        let menu = makeMenu(items: [("b1", "Classic Burger", []), ("s1", "Side Salad", [])])
        let draft = parser.parseDraft(transcript: "burger", existingDraft: makeDraft(), menu: menu)
        XCTAssertFalse(draft.items.isEmpty, "Should match at least one item")
        XCTAssertTrue(draft.items.contains { $0.menuItemId == "b1" }, "Should match Classic Burger")
    }

    func test_parseDraft_returnsEmptyForUnknownItem() {
        let menu = makeMenu(items: [("b1", "Cheeseburger", [])])
        let draft = parser.parseDraft(transcript: "xyzzy", existingDraft: makeDraft(), menu: menu)
        XCTAssertTrue(draft.items.isEmpty)
    }

    func test_parseDraft_deduplicatesWithinSameSeat() {
        let menu = makeMenu(items: [("b1", "Cheeseburger", [])])
        var existing = makeDraft()
        existing = parser.parseDraft(transcript: "cheeseburger", existingDraft: existing, menu: menu)
        // Parse same thing again — should not duplicate
        let result = parser.parseDraft(transcript: "cheeseburger", existingDraft: existing, menu: menu)
        XCTAssertEqual(result.items.filter { $0.menuItemId == "b1" }.count, 1)
    }

    // MARK: - Quantity extraction

    func test_parseDraft_extractsQuantity() {
        let menu = makeMenu(items: [("b1", "Cheeseburger", [])])
        let draft = parser.parseDraft(transcript: "2 cheeseburgers", existingDraft: makeDraft(), menu: menu)
        XCTAssertEqual(draft.items.first?.quantity, 2)
    }

    // MARK: - Course inference from tags (Fix: no longer defaults everything to .entree)

    func test_courseInference_beverageTagYieldsBeverageCourse() {
        let menu = makeMenu(items: [("c1", "Cola", ["beverage"])])
        let draft = parser.parseDraft(transcript: "cola", existingDraft: makeDraft(), menu: menu)
        XCTAssertEqual(draft.items.first?.course, .beverage,
                       "Item tagged 'beverage' should get .beverage course without explicit keyword")
    }

    func test_courseInference_dessertTagYieldsDessertCourse() {
        let menu = makeMenu(items: [("d1", "Chocolate Cake", ["dessert"])])
        let draft = parser.parseDraft(transcript: "chocolate cake", existingDraft: makeDraft(), menu: menu)
        XCTAssertEqual(draft.items.first?.course, .dessert)
    }

    func test_courseInference_sideTagYieldsSideCourse() {
        let menu = makeMenu(items: [("s1", "Side Fries", ["side"])])
        let draft = parser.parseDraft(transcript: "side fries", existingDraft: makeDraft(), menu: menu)
        XCTAssertEqual(draft.items.first?.course, .side)
    }

    func test_courseInference_untaggedItemDefaultsToEntree() {
        let menu = makeMenu(items: [("b1", "Burger", [])])
        let draft = parser.parseDraft(transcript: "burger", existingDraft: makeDraft(), menu: menu)
        XCTAssertEqual(draft.items.first?.course, .entree)
    }

    func test_courseKeywordOverridesTagInference() {
        let menu = makeMenu(items: [("b1", "Cheeseburger", ["side"])])
        // "entree, cheeseburger" — explicit "entree" keyword overrides side tag
        let draft = parser.parseDraft(transcript: "entree, cheeseburger", existingDraft: makeDraft(), menu: menu)
        XCTAssertEqual(draft.items.first?.course, .entree)
    }

    func test_beverageCourseKeyword_setsCourseForUntaggedItem() {
        let menu = makeMenu(items: [("c1", "Cola", [])])
        let draft = parser.parseDraft(transcript: "drinks, cola", existingDraft: makeDraft(), menu: menu)
        XCTAssertEqual(draft.items.first?.course, .beverage)
    }

    // MARK: - Modifier negation (Fix: name is bare modifier name, isNegation: true)

    func test_modifierNegation_setsIsNegationTrue_notStringPrefix() {
        let menu = makeMenu(items: [("b1", "Burger", [], [("r1", "Ranch")])])
        let draft = parser.parseDraft(transcript: "burger no ranch", existingDraft: makeDraft(), menu: menu)
        guard let item = draft.items.first else { return XCTFail("No item parsed") }
        let negated = item.negations
        let names = item.modifierNames
        // The modifier name should be "Ranch", not "No Ranch"
        XCTAssertFalse(names.contains("No Ranch"), "Modifier name must not include 'No' prefix")
        XCTAssertTrue(names.contains("Ranch"), "Modifier name should be bare 'Ranch'")
        XCTAssertTrue(negated.contains("Ranch"), "Ranch should appear in negations list")
    }

    func test_nonNegatedModifier_isNegationFalse() {
        let menu = makeMenu(items: [("b1", "Burger", [], [("r1", "Ranch")])])
        let draft = parser.parseDraft(transcript: "burger ranch", existingDraft: makeDraft(), menu: menu)
        guard let item = draft.items.first else { return XCTFail("No item parsed") }
        XCTAssertFalse(item.negations.contains("Ranch"), "Non-negated modifier should not be in negations")
        XCTAssertTrue(item.modifierNames.contains("Ranch"))
    }

    // MARK: - Allergy detection

    func test_allergyFlag_setOnAllergyKeyword() {
        let menu = makeMenu(items: [("b1", "Cheeseburger", [])])
        let draft = parser.parseDraft(transcript: "cheeseburger allergy", existingDraft: makeDraft(), menu: menu)
        XCTAssertTrue(draft.items.first?.hasAllergyFlag == true)
    }

    // MARK: - Repeat-back summary

    func test_repeatBack_formatsItems() {
        let menu = makeMenu(items: [("b1", "Cheeseburger", [])])
        let draft = parser.parseDraft(transcript: "cheeseburger", existingDraft: makeDraft(), menu: menu)
        let summary = parser.repeatBackSummary(for: draft)
        XCTAssertTrue(summary.contains("Cheeseburger"))
    }

    func test_repeatBack_emptyDraft() {
        let summary = parser.repeatBackSummary(for: makeDraft())
        XCTAssertEqual(summary, "No items yet.")
    }
}
