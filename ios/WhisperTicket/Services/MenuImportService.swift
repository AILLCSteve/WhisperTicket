import Foundation

/// Stub implementation — returns a placeholder result.
/// Replace with OpenAIMenuImportService in Phase 2:
///   1. Read file data
///   2. For PDF: extract pages as images (PDFKit)
///   3. POST to https://api.openai.com/v1/chat/completions with vision model
///   4. System prompt instructs model to return strict MenuV1 JSON
///   5. Parse response into MenuV1
///   6. Return .success(menu) or .failure(rawResponse)
final class StubMenuImportService: MenuImportServiceProtocol {
    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult {
        // Simulate async work
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return .failure(
            "Menu import not yet connected. File received: \(fileURL.lastPathComponent). " +
            "Phase 2: wire OpenAIMenuImportService here with your API key."
        )
    }
}
