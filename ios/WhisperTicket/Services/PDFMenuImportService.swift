import Foundation
import PDFKit

/// Extracts menu items from a PDF file using PDFKit text extraction,
/// then delegates to MenuTextParser for the heuristic text → MenuV1 conversion.
final class PDFMenuImportService: MenuImportServiceProtocol {
    private let textParser = MenuTextParser()

    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult {
        guard fileType == .pdf else {
            return .failure("PDFMenuImportService only handles PDF files.")
        }
        return await Task.detached(priority: .userInitiated) {
            self.parsePDF(at: fileURL)
        }.value
    }

    private func parsePDF(at url: URL) -> MenuImportResult {
        // Acquire security-scoped access for URLs originating from the document picker.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let document = PDFDocument(url: url) else {
            return .failure("Could not open PDF: \(url.lastPathComponent)")
        }

        var fullText = ""
        for i in 0 ..< document.pageCount {
            if let page = document.page(at: i), let pageText = page.string {
                fullText += pageText + "\n"
            }
        }

        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("PDF appears to contain no readable text. If it is a scanned menu, use the Photo import option instead.")
        }

        let restaurantName = url.deletingPathExtension().lastPathComponent
        return textParser.parse(fullText, restaurantName: restaurantName)
    }
}
