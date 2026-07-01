import Foundation
import AVFoundation
import Combine

// MARK: - Audio Capture

protocol AudioCaptureServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    /// Normalized 0...1 microphone level, for the live waveform.
    var noiseLevel: Float { get }
    /// Begin recording microphone audio to a file. Records continuously until
    /// stopRecording() is called — no timers, no silence handling.
    func startRecording() throws
    /// Stop recording and return the finalized audio file URL, or nil if nothing
    /// was captured. The caller owns the file and should delete it when done.
    func stopRecording() -> URL?
    func interruptionPublisher() -> AnyPublisher<Void, Never>
}

// MARK: - Transcription

protocol TranscriptionServiceProtocol: AnyObject {
    /// Transcribe a complete audio file in one shot — no streaming, no partial
    /// results, no session state. Returns the full transcript text (may be empty).
    func transcribe(fileURL: URL) async throws -> String
}

// MARK: - Order Parser

protocol OrderParserProtocol {
    func parseDraft(transcript: String, existingDraft: TicketDraft, menu: MenuV1) -> TicketDraft
    func detectMacro(in text: String) -> VoiceMacro?
    func repeatBackSummary(for draft: TicketDraft) -> String
}

// MARK: - Menu Store

protocol MenuStoreProtocol: AnyObject {
    var menu: MenuV1? { get }
    func loadMenu() async throws
    func saveMenu(_ newMenu: MenuV1)
    func findBestMatches(text: String, maxResults: Int) -> [(item: MenuItem, score: Double)]
    func item(byId id: String) -> MenuItem?
}

// MARK: - Ticket Repository

protocol TicketRepositoryProtocol {
    func fetchAll() async throws -> [Ticket]
    func fetchOpen() async throws -> [Ticket]
    func save(_ ticket: Ticket) async throws
    func delete(_ ticket: Ticket) async throws
    func deleteItem(_ item: TicketItem) async throws
    func deleteAll() async throws
    func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket
}

// MARK: - Upsell Engine

protocol UpsellEngineProtocol {
    func suggestions(for draft: TicketDraft, menu: MenuV1) -> [UpsellSuggestionResult]
}

// MARK: - Menu Import

// Menu import result — either a parsed menu or an error with raw response for debugging
enum MenuImportResult {
    case success(MenuV1)
    case failure(String)      // human-readable error; preserve raw AI response for debugging
}

protocol MenuImportServiceProtocol {
    /// Import a menu from a PDF or image file at the given URL.
    /// Implementations should send the file to an AI service (e.g., OpenAI Vision)
    /// and parse the response into MenuV1 format.
    func importMenu(from fileURL: URL, fileType: MenuImportFileType) async -> MenuImportResult
}

enum MenuImportFileType: String {
    case pdf
    case image    // JPEG, PNG, HEIC
}

struct UpsellSuggestionResult: Identifiable {
    let id: String = UUID().uuidString
    let menuItem: MenuItem
    let reason: String
    let playbookScript: String?
}
