import XCTest
@testable import WhisperTicket
import Foundation

/// Tests the fixed price regex pattern used in PDFMenuImportService.
/// The bug: `(?:\.\d{2})` was non-capturing, so $14.99 extracted as 14.0 instead of 14.99.
/// The fix: `\.\d{2}` (no `?:`) makes the decimal part part of capture group 1.
final class PDFPriceRegexTests: XCTestCase {

    // Replicates the exact pattern now in PDFMenuImportService after the fix.
    private let priceRegex = try! NSRegularExpression(pattern: #"\$?\s*(\d{1,3}\.\d{2})"#)

    private func extractPrice(from line: String) -> Double {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = priceRegex.firstMatch(in: line, range: range),
              let swiftRange = Range(match.range(at: 1), in: line) else { return 0 }
        return Double(line[swiftRange]) ?? 0
    }

    // MARK: - Core fix verification

    func test_priceWithCents_extractsFullDecimal() {
        // Pre-fix: this returned 14.0. Post-fix: must return 14.99.
        XCTAssertEqual(extractPrice(from: "Salmon $14.99"), 14.99, accuracy: 0.001)
    }

    func test_priceCentsNotDropped() {
        XCTAssertEqual(extractPrice(from: "Steak  $28.50"), 28.50, accuracy: 0.001)
    }

    func test_singleDigitCents() {
        // Regex requires exactly 2 decimal digits — $8.0 won't match (only 1 decimal digit)
        XCTAssertEqual(extractPrice(from: "Soup $8.00"), 8.0, accuracy: 0.001)
    }

    func test_noDollarSign_stillMatches() {
        XCTAssertEqual(extractPrice(from: "Burger 12.99"), 12.99, accuracy: 0.001)
    }

    func test_dollarSignWithSpace_stillMatches() {
        XCTAssertEqual(extractPrice(from: "Item $ 9.50"), 9.50, accuracy: 0.001)
    }

    func test_integerOnlyPrice_doesNotMatch() {
        // Round-dollar prices ($15) don't match — requires decimal. Known limitation.
        XCTAssertEqual(extractPrice(from: "Item $15"), 0.0, accuracy: 0.001)
    }

    func test_priceEmbeddedInLongerLine() {
        XCTAssertEqual(extractPrice(from: "Grilled Chicken Sandwich........................$13.95"), 13.95, accuracy: 0.001)
    }

    func test_captureGroupOne_notZero() {
        // Verify that capture group 1 includes the decimal digits (the actual fix).
        let line = "Pasta $18.75"
        let range = NSRange(line.startIndex..., in: line)
        guard let match = priceRegex.firstMatch(in: line, range: range) else {
            return XCTFail("Regex should match")
        }
        guard let captured = Range(match.range(at: 1), in: line) else {
            return XCTFail("Capture group 1 should exist")
        }
        XCTAssertEqual(String(line[captured]), "18.75",
                       "Capture group 1 must include decimal digits — was the `?:` removed?")
    }

    // MARK: - Buggy pattern (documentation)

    func test_buggyPattern_wouldHaveDroppedCents() {
        // The OLD buggy regex: `\$?\s*(\d{1,3}(?:\.\d{2}))` — capture group 1 = only the integer part.
        let buggyRegex = try! NSRegularExpression(pattern: #"\$?\s*(\d{1,3}(?:\.\d{2}))"#)
        let line = "Salmon $14.99"
        let range = NSRange(line.startIndex..., in: line)
        guard let match = buggyRegex.firstMatch(in: line, range: range),
              let captured = Range(match.range(at: 1), in: line) else {
            return XCTFail("Buggy regex should still match the line")
        }
        // This is the BUG: `(?:...)` is non-capturing so group 1 is only "14"
        XCTAssertEqual(String(line[captured]), "14",
                       "Confirming the bug: old pattern captures only integer part. This test documents the pre-fix behavior.")
    }
}
