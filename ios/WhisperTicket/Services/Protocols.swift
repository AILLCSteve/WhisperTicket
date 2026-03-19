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
}

// MARK: - Transcription

protocol TranscriptionServiceProtocol: AnyObject {
    func transcriptionPublisher() -> AnyPublisher<TranscriptionSegment, Never>
    func startTranscribing(audioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>) throws
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
    func findBestMatches(text: String, maxResults: Int) -> [(item: MenuItem, score: Double)]
    func item(byId id: String) -> MenuItem?
}

// MARK: - Ticket Repository

protocol TicketRepositoryProtocol {
    func fetchAll() async throws -> [Ticket]
    func fetchOpen() async throws -> [Ticket]
    func save(_ ticket: Ticket) async throws
    func delete(_ ticket: Ticket) async throws
    func deleteItem(_ item: TicketItem) async throws      // NEW
    func createTicket(from draft: TicketDraft, serverId: String) async throws -> Ticket
}

// MARK: - Upsell Engine

protocol UpsellEngineProtocol {
    func suggestions(for draft: TicketDraft, menu: MenuV1) -> [UpsellSuggestionResult]
}

struct UpsellSuggestionResult: Identifiable {
    let id: String = UUID().uuidString
    let menuItem: MenuItem
    let reason: String
    let playbookScript: String?
}
