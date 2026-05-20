import XCTest
@testable import WhisperTicket

final class TranscriptCleanerTests: XCTestCase {

    func test_removesOpeningOrderPhrase() {
        let result = TranscriptCleaner.clean("I would like to have a burger")
        XCTAssertEqual(result.lowercased(), "burger")
    }

    func test_removesCanIGet() {
        let result = TranscriptCleaner.clean("Can I get the chicken sandwich")
        XCTAssertTrue(result.lowercased().contains("chicken sandwich"), "Got: \(result)")
        XCTAssertFalse(result.lowercased().contains("can i get"), "Filler not removed: \(result)")
    }

    func test_removesIllHave() {
        let result = TranscriptCleaner.clean("I'll have the pasta please")
        XCTAssertTrue(result.lowercased().contains("pasta"), "Got: \(result)")
        XCTAssertFalse(result.lowercased().contains("i'll have"), "Filler not removed: \(result)")
        XCTAssertFalse(result.lowercased().contains("please"), "Trailing courtesy not removed: \(result)")
    }

    func test_preservesNegationModifiers() {
        let result = TranscriptCleaner.clean("I would like a burger with no onions")
        XCTAssertTrue(result.lowercased().contains("no onions"),
                      "Negation modifier 'no' must be preserved. Got: \(result)")
    }

    func test_preservesWithModifier() {
        let result = TranscriptCleaner.clean("Can I get the steak with extra sauce")
        XCTAssertTrue(result.lowercased().contains("with extra sauce"),
                      "Modifier phrase 'with extra sauce' must be preserved. Got: \(result)")
    }

    func test_collapsesWhitespace() {
        let result = TranscriptCleaner.clean("um uh the burger")
        XCTAssertFalse(result.hasPrefix(" "), "Result must not start with space")
        XCTAssertFalse(result.contains("  "), "Result must not contain double spaces")
    }

    func test_caseInsensitiveRemoval() {
        let result1 = TranscriptCleaner.clean("CAN I GET a salad")
        let result2 = TranscriptCleaner.clean("can i get a salad")
        XCTAssertEqual(result1.lowercased(), result2.lowercased())
    }

    func test_emptyInputReturnsEmpty() {
        let result = TranscriptCleaner.clean("")
        XCTAssertEqual(result, "")
    }

    func test_fillerOnlyInputReturnsEmpty() {
        let result = TranscriptCleaner.clean("um uh yeah okay")
        XCTAssertEqual(result.trimmingCharacters(in: .whitespaces), "")
    }

    func test_longestPhraseRemovedFirst() {
        // "i would like to have" must be removed before "i would like" to avoid partial removal
        let result = TranscriptCleaner.clean("i would like to have the pasta")
        XCTAssertTrue(result.lowercased().contains("pasta"), "Got: \(result)")
        XCTAssertFalse(result.lowercased().contains("like to have"), "Longer phrase not fully removed: \(result)")
    }
}
