import Foundation
import Vision
import UIKit

/// Extracts menu items from a photo or screenshot using Vision on-device OCR,
/// then delegates to MenuTextParser for the heuristic text → MenuV1 conversion.
/// Supports JPEG, PNG, HEIC, and any other format UIImage can decode.
final class PhotoMenuImportService: MenuImportServiceProtocol {
    private let textParser = MenuTextParser()

    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult {
        guard fileType == .image else {
            return .failure("PhotoMenuImportService only handles image files.")
        }
        return await Task.detached(priority: .userInitiated) {
            self.performOCR(at: fileURL)
        }.value
    }

    /// Entry point for callers that have image Data rather than a file URL
    /// (e.g. from PhotosUI.PhotosPicker which vends transferable Data).
    func importMenu(from imageData: Data, name: String) async -> MenuImportResult {
        return await Task.detached(priority: .userInitiated) {
            self.performOCROnData(imageData, name: name)
        }.value
    }

    // MARK: - OCR

    private func performOCR(at url: URL) -> MenuImportResult {
        // Handle security-scoped URLs from the document picker.
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let imageData = try? Data(contentsOf: url) else {
            return .failure("Could not read image file: \(url.lastPathComponent)")
        }
        let name = url.deletingPathExtension().lastPathComponent
        return performOCROnData(imageData, name: name)
    }

    private func performOCROnData(_ data: Data, name: String) -> MenuImportResult {
        guard let uiImage = UIImage(data: data), let cgImage = uiImage.cgImage else {
            return .failure("Could not decode image data.")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Revision 3 (iOS 16+) gives the best accuracy for printed menus.
        if #available(iOS 16.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return .failure("OCR processing failed: \(error.localizedDescription)")
        }

        guard let observations = request.results, !observations.isEmpty else {
            return .failure("No text found in the image. Make sure the menu is in focus and well-lit.")
        }

        // Sort observations top-to-bottom (Vision uses a flipped coordinate system
        // where y=0 is at the bottom of the image, so larger y = higher on screen).
        let sorted = observations.sorted { $0.boundingBox.minY > $1.boundingBox.minY }
        let fullText = sorted
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")

        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("Could not extract readable text from the image.")
        }

        let menuName = name.isEmpty ? "Imported Menu" : name
        return textParser.parse(fullText, restaurantName: menuName)
    }
}
