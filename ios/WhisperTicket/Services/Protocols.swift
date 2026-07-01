import Foundation
import AVFoundation
import Combine

// MARK: - Audio Capture

protocol AudioCaptureServiceProtocol: AnyObject {
    var isRecording: Bool { get }
    var noiseLevel: Float { get }
    func startCapture() throws
    func stopCapture()
    func audioBufferPublisher() -> AnyPublisher<AVAudioPCMBuffer, Never>
    func interruptionPublisher() -> AnyPublisher<Void, Never>
}

// MARK: - Transcription

protocol TranscriptionServiceProtocol: AnyObject {
    func transcriptionPublisher() -> AnyPublisher<TranscriptionSegment, Never>
    /// Starts streaming transcription. `seed` is any transcript that already exists
    /// for the target seat; the service treats it as the immutable prefix so the
    /// emitted transcript is the single source of truth (prior text + new speech)
    /// and never regresses. Pass "" for a fresh seat.
    func startTranscribing(audioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>, seed: String) throws
    /// Immediately seals the session (isSessionActive = false, endAudio) without
    /// cancelling the existing recognition task. Allows the final drain to deliver
    /// its last segment before stopTranscribing() cleans up. Call in stopRecording().
    func endAudioInput()
    func stopTranscribing()
}

struct TranscriptionSegment {
    let text: String
    let isFinal: Bool
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
