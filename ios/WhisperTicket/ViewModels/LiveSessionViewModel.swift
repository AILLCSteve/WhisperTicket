import Foundation
import Observation
import Combine

@Observable
final class LiveSessionViewModel {
    // Per-seat transcripts: seatNumber → transcript text
    var seatTranscripts: [Int: String] = [:]
    var draft: TicketDraft
    var upsellSuggestions: [UpsellSuggestionResult] = []
    var isRecording = false
    var noiseLevel: Float = 0.0
    var showNoisyEnvironmentWarning = false
    var showRepeatBack = false
    var detectedMacro: VoiceMacro? = nil
    var errorMessage: String? = nil
    var allergyItemsPendingConfirm: [DraftItem] = []
    var isFinalizingTranscription = false
    var activeSeatNumber: Int = 1
    var activeSeatLabel: String = ""

    /// Live text for the currently active seat (updates during recording).
    var activeSeatTranscript: String {
        seatTranscripts[activeSeatNumber] ?? ""
    }

    private let audioCapture: AudioCaptureServiceProtocol
    private let transcriptionService: TranscriptionServiceProtocol
    private let parser: OrderParserProtocol
    private let menuStore: MenuStoreProtocol
    private let upsellEngine: UpsellEngineProtocol
    private var cancellables = Set<AnyCancellable>()
    private var finalizationTimer: AnyCancellable?
    private var transcriptionCancellable: AnyCancellable?
    // Stores transcript text that existed for the active seat before the current
    // recording session began. New ASR segments are prepended with this so
    // multiple mic presses accumulate rather than overwrite.
    private var priorSeatTranscript = ""

    let noiseWarningThreshold: Float = 0.75

    init(
        tableNumber: String,
        audioCapture: AudioCaptureServiceProtocol,
        transcriptionService: TranscriptionServiceProtocol,
        parser: OrderParserProtocol,
        menuStore: MenuStoreProtocol,
        upsellEngine: UpsellEngineProtocol
    ) {
        self.draft = TicketDraft(tableNumber: tableNumber)
        self.audioCapture = audioCapture
        self.transcriptionService = transcriptionService
        self.parser = parser
        self.menuStore = menuStore
        self.upsellEngine = upsellEngine
    }

    func startRecording() {
        do {
            // Capture whatever transcript already exists for this seat BEFORE starting ASR.
            // New ASR segments will be prepended with this text so users can press record
            // multiple times without losing prior speech.
            priorSeatTranscript = seatTranscripts[activeSeatNumber] ?? ""

            // Position the parse cursor so the parser skips already-processed prior text.
            // If prior text exists, new words start after a space separator (+1).
            draft.consumedCursor = priorSeatTranscript.isEmpty
                ? 0
                : priorSeatTranscript.count + 1

            try audioCapture.startCapture()
            let audioPublisher = audioCapture.audioBufferPublisher()
            try transcriptionService.startTranscribing(audioPublisher: audioPublisher)
            isRecording = true

            transcriptionCancellable = transcriptionService.transcriptionPublisher()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] segment in self?.handleTranscriptionSegment(segment) }

            Timer.publish(every: 0.5, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.checkNoiseLevel() }
                .store(in: &cancellables)

        } catch {
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        audioCapture.stopCapture()
        isRecording = false
        isFinalizingTranscription = true
        noiseLevel = 0.0
        showNoisyEnvironmentWarning = false
        cancellables.removeAll()

        finalizationTimer = Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .first()
            .sink { [weak self] _ in self?.finalizeTranscription() }
    }

    func triggerRepeatBack() {
        showRepeatBack = true
    }

    func confirmAllergyItem(_ item: DraftItem) {
        allergyItemsPendingConfirm.removeAll { $0.id == item.id }
    }

    func removeItem(_ item: DraftItem) {
        draft.items.removeAll { $0.id == item.id }
        refreshUpsells()
    }

    func addManualItem(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let item = DraftItem(
            menuItemId: "manual_\(UUID().uuidString)",
            name: trimmed,
            quantity: 1,
            modifierNames: [], negations: [],
            course: .entree,
            seatNumber: activeSeatNumber,
            notes: "", confidence: 1.0, hasAllergyFlag: false
        )
        draft.items.append(item)
        refreshUpsells()
    }

    func clearSeat(_ seatNumber: Int) {
        draft.items.removeAll { $0.seatNumber == seatNumber }
        seatTranscripts.removeValue(forKey: seatNumber)
        draft.seatTranscripts.removeValue(forKey: seatNumber)
        // If the active seat is being cleared, reset the prior-session accumulator
        // so the next recording starts truly fresh.
        if seatNumber == activeSeatNumber {
            priorSeatTranscript = ""
            draft.consumedCursor = 0
        }
        refreshUpsells()
    }

    func itemsBySeat() -> [(seatNumber: Int, items: [DraftItem])] {
        let allSeats = Set(draft.items.compactMap { $0.seatNumber }).sorted()
        let unseated = draft.items.filter { $0.seatNumber == nil }
        var result = allSeats.map { seat in
            (seatNumber: seat, items: draft.items.filter { $0.seatNumber == seat })
        }
        if !unseated.isEmpty { result.append((seatNumber: 0, items: unseated)) }
        return result
    }

    func applyMacro(_ macro: VoiceMacro, previousDraft: TicketDraft?) {
        switch macro {
        case .repeatLastOrder:
            if let prev = previousDraft { draft.items = prev.items }
        case .addSideSalad:
            if let menu = menuStore.menu,
               let salad = menu.categories.flatMap({ $0.items }).first(where: { $0.name.lowercased().contains("side salad") }) {
                let item = DraftItem(
                    menuItemId: salad.id, name: salad.name, quantity: 1,
                    modifierNames: [], negations: [], course: .side,
                    seatNumber: nil, notes: "", confidence: 1.0, hasAllergyFlag: false
                )
                draft.addItem(item)
            }
        case .splitCheck:
            break
        }
        detectedMacro = nil
        refreshUpsells()
    }

    // MARK: - Private

    private func handleTranscriptionSegment(_ segment: TranscriptionSegment) {
        // Build the full seat transcript: everything spoken before this recording session
        // (priorSeatTranscript) + whatever ASR has produced in this session (segment.text).
        let fullText: String
        if priorSeatTranscript.isEmpty {
            fullText = segment.text
        } else {
            fullText = "\(priorSeatTranscript) \(segment.text)"
        }

        seatTranscripts[activeSeatNumber] = fullText
        draft.seatTranscripts[activeSeatNumber] = fullText
        draft.rawTranscript = fullText

        if let macro = parser.detectMacro(in: segment.text) {
            detectedMacro = macro
        }

        guard let menu = menuStore.menu else { return }

        let previousIds = Set(draft.items.map { $0.id })
        let updatedDraft = parser.parseDraft(transcript: fullText, existingDraft: draft, menu: menu)
        draft = updatedDraft
        // Re-sync per-seat transcripts after parseDraft replaces the draft struct.
        draft.seatTranscripts = seatTranscripts
        draft.rawTranscript = fullText

        // Stamp newly added items with the active seat.
        for i in draft.items.indices where !previousIds.contains(draft.items[i].id) {
            draft.items[i].seatNumber = activeSeatNumber
        }

        let existingIds = Set(allergyItemsPendingConfirm.map { $0.id })
        let newAllergyItems = draft.items.filter { $0.hasAllergyFlag && !existingIds.contains($0.id) }
        allergyItemsPendingConfirm.append(contentsOf: newAllergyItems)

        refreshUpsells()
    }

    private func finalizeTranscription() {
        finalizationTimer?.cancel()
        finalizationTimer = nil
        transcriptionCancellable?.cancel()
        transcriptionCancellable = nil
        transcriptionService.stopTranscribing()
        isFinalizingTranscription = false

        // If this seat produced no parsed items, add the cleaned transcript as a
        // fallback item so "Review & Send" always has content for the kitchen.
        let transcript = seatTranscripts[activeSeatNumber] ?? ""
        let hasSeatItems = draft.items.contains { $0.seatNumber == activeSeatNumber }
        if !hasSeatItems && !transcript.isEmpty {
            let cleaned = TranscriptCleaner.clean(transcript)
            if !cleaned.isEmpty {
                let item = DraftItem(
                    menuItemId: "transcript_\(activeSeatNumber)_\(UUID().uuidString)",
                    name: cleaned,
                    quantity: 1,
                    modifierNames: [], negations: [],
                    course: .entree,
                    seatNumber: activeSeatNumber,
                    notes: "", confidence: 0.5, hasAllergyFlag: false
                )
                draft.items.append(item)
                refreshUpsells()
            }
        }
    }

    private func checkNoiseLevel() {
        noiseLevel = audioCapture.noiseLevel
        showNoisyEnvironmentWarning = noiseLevel > noiseWarningThreshold
    }

    private func refreshUpsells() {
        guard let menu = menuStore.menu else { return }
        upsellSuggestions = upsellEngine.suggestions(for: draft, menu: menu)
    }
}

// MARK: - Transcript Filler Word Cleaner

/// Removes common spoken filler words and ordering phrases from a voice transcript,
/// preserving all food-relevant content including critical modifiers like
/// "with", "without", "no", "extra", "sub", etc.
enum TranscriptCleaner {

    // Ordered longest → shortest so longer phrases are stripped before their substrings.
    private static let fillerPhrases: [String] = [
        // Multi-word opening order phrases
        "i would like to have",
        "i would like to get",
        "i would like",
        "i'd like to have",
        "i'd like to get",
        "i'd like",
        "can i please get",
        "can i please have",
        "can i get",
        "can i have",
        "could i please get",
        "could i please have",
        "could i get",
        "could i have",
        "i'll have the",
        "i'll have",
        "i'll take the",
        "i'll take",
        "let me get the",
        "let me get",
        "let me have",
        "give me the",
        "give me",
        "i want the",
        "i want",
        "we would like",
        "we'd like",
        "we'll have the",
        "we'll have",
        "we want",
        "make that",
        "and then i'll have",
        "and then",
        "for me i'll have",
        "for me",
        "going to go with",
        "going to get",
        "going to have",
        "going to",
        "gonna have",
        "gonna get",
        "gonna",
        "want to get",
        "wanna get",
        "want to",
        "wanna",
        // Filler sentence starters
        "you know what",
        "you know",
        "i think i'll",
        "i think",
        "i guess i'll go with",
        "i guess i'll",
        "i guess",
        "maybe i'll have",
        "maybe i'll",
        "maybe i",
        "actually i'll",
        "actually",
        "so i'll",
        "so i'd like",
        "so can i",
        "kind of like",
        "kind of",
        "sort of like",
        "sort of",
        "i mean",
        "basically",
        "literally",
        // Courtesy / trailing
        "thank you very much",
        "thank you",
        "thanks",
        "please",
        // Single filler words (after multi-word phrases to avoid partial wipe)
        "just",
        "um",
        "uh",
        "er",
        "hmm",
        "hm",
        "uhh",
        "umm",
        "ehh",
        "eh",
        "yeah so",
        "yeah yeah",
        "yeah",
        "yes so",
        "yes",
        "okay so",
        "okay",
        "alright so",
        "alright",
        "right so",
        "right",
        "sure",
    ]

    static func clean(_ transcript: String) -> String {
        var text = transcript
        // Replace each filler phrase (case-insensitive). Longest first ensures
        // "i would like to have" is matched before "i would like".
        for phrase in fillerPhrases {
            text = text.replacingOccurrences(of: phrase, with: " ", options: .caseInsensitive)
        }
        // Collapse whitespace and trim
        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
