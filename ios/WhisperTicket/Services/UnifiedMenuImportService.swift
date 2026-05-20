import Foundation

/// Routes import requests to the appropriate service based on file type.
/// PDF files → PDFMenuImportService (PDFKit text extraction).
/// Image files → PhotoMenuImportService (Vision OCR).
final class UnifiedMenuImportService: MenuImportServiceProtocol {
    private let pdfService = PDFMenuImportService()
    private let photoService = PhotoMenuImportService()

    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult {
        switch fileType {
        case .pdf:   return await pdfService.importMenu(from: fileURL, fileType: .pdf)
        case .image: return await photoService.importMenu(from: fileURL, fileType: .image)
        }
    }

    /// Convenience for callers with raw image Data (e.g. PhotosUI.PhotosPicker).
    func importMenu(from imageData: Data, name: String) async -> MenuImportResult {
        await photoService.importMenu(from: imageData, name: name)
    }
}
