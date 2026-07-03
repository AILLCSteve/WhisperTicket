import Foundation
import Observation
import Combine

@MainActor
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
    /// Feeds completed segment files, in recording order, to the serial consumer.
    private var segmentContinuation: AsyncStream<URL>.Continuation?
    /// The serial consumer for the CURRENT recording session.
    private var segmentConsumerTask: Task<Void, Never>?

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

    /// Start recording microphone audio. Capture rotates to a new file whenever
    /// the speaker pauses (see AudioCaptureService); each finished segment is
    /// transcribed in the background while recording continues. There is NO
    /// recording length limit. The transcript is appended ONCE, on stop, after
    /// all segments have been transcribed — so nothing can erase mid-recording
    /// and nothing before a pause can be dropped.
    func startRecording() {
        do {
            let (stream, continuation) = AsyncStream<URL>.makeStream()
            segmentContinuation = continuation

            // Capture-service callback fires on an arbitrary thread; hop to the
            // MainActor before touching state.
            audioCapture.onSegmentReady = { url in
                Task { @MainActor [weak self] in
                    self?.segmentContinuation?.yield(url)
                }
            }

            // Serial consumer: transcribes segments strictly in arrival order.
            segmentConsumerTask = Task { [weak self] in
                var texts: [String] = []
                for await url in stream {
                    guard let self else { return }
                    do {
                        let text = try await self.transcriptionService.transcribe(fileURL: url)
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { texts.append(trimmed) }
                    } catch {
                        // One bad segment must not sink the others. Surface it,
                        // keep going — the remaining segments still transcribe.
                        self.errorMessage = "Part of the recording could not be transcribed."
                    }
                    try? FileManager.default.removeItem(at: url)
                }
                guard let self else { return }
                let joined = texts.joined(separator: " ")
                self.appendTranscript(joined)          // no-op if empty (existing guard)
                self.isFinalizingTranscription = false
            }

            try audioCapture.startRecording()
            isRecording = true
            errorMessage = nil
            showNoisyEnvironmentWarning = false

            audioCapture.interruptionPublisher()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    // Phone call etc. Treat like a stop: finalize the last file
                    // and transcribe everything captured so nothing is lost.
                    self?.finishRecording(interrupted: true)
                }
                .store(in: &cancellables)

            Timer.publish(every: 0.3, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in self?.checkNoiseLevel() }
                .store(in: &cancellables)

        } catch {
            isRecording = false
            segmentContinuation?.finish()
            segmentContinuation = nil
            errorMessage = "Could not start recording: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        finishRecording(interrupted: false)
    }

    /// Stop capture, enqueue the final segment, and close the stream. The serial
    /// consumer drains any remaining segments (usually zero — they transcribed
    /// during recording) and then performs the single append + parse.
    private func finishRecording(interrupted: Bool) {
        guard isRecording else { return }
        isRecording = false
        cancellables.removeAll()   // stop meter poll + interruption subscription
        noiseLevel = 0.0
        showNoisyEnvironmentWarning = false
        audioCapture.onSegmentReady = nil

        isFinalizingTranscription = true   // cleared by the consumer when drained

        let finalURL = audioCapture.stopRecording()
        if interrupted {
            errorMessage = "Recording interrupted — transcribing what was captured."
        }

        if let finalURL {
            segmentContinuation?.yield(finalURL)
        }
        segmentContinuation?.finish()
        segmentContinuation = nil
        // Deliberately NOT cancelling segmentConsumerTask — it must drain.
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

    func updateItem(_ updated: DraftItem) {
        guard let idx = draft.items.firstIndex(where: { $0.id == updated.id }) else { return }
        draft.items[idx] = updated
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

    /// Append one completed recording's transcript to the active seat and parse it.
    /// Pure append + parse-once: nothing re-reads prior audio or re-parses prior
    /// text, so this can neither erase existing text nor duplicate existing items.
    private func appendTranscript(_ newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let existing = seatTranscripts[activeSeatNumber] ?? ""
        let combined = existing.isEmpty ? trimmed : "\(existing) \(trimmed)"
        seatTranscripts[activeSeatNumber] = combined
        draft.seatTranscripts[activeSeatNumber] = combined
        draft.rawTranscript = combined

        if let macro = parser.detectMacro(in: trimmed) {
            detectedMacro = macro
        }

        guard let menu = menuStore.menu else { return }

        // Parse ONLY this recording's chunk (cursor 0 over `trimmed`). Each chunk is
        // parsed exactly once and its items appended — no re-processing of prior text.
        let previousIds = Set(draft.items.map { $0.id })
        draft.consumedCursor = 0
        var parsed = parser.parseDraft(transcript: trimmed, existingDraft: draft, menu: menu)
        parsed.seatTranscripts = seatTranscripts
        parsed.rawTranscript = combined
        draft = parsed

        // Stamp newly added items with the active seat.
        for i in draft.items.indices where !previousIds.contains(draft.items[i].id) {
            draft.items[i].seatNumber = activeSeatNumber
        }

        let existingIds = Set(allergyItemsPendingConfirm.map { $0.id })
        let newAllergyItems = draft.items.filter { $0.hasAllergyFlag && !existingIds.contains($0.id) }
        allergyItemsPendingConfirm.append(contentsOf: newAllergyItems)

        // Fallback: nothing matched this chunk → keep the spoken text as an off-menu
        // line so the kitchen still sees it. Deterministic id dedups repeats.
        let hasSeatItems = draft.items.contains { $0.seatNumber == activeSeatNumber }
        if !hasSeatItems {
            let cleaned = TranscriptCleaner.clean(trimmed)
            if !cleaned.isEmpty {
                var item = DraftItem(
                    menuItemId: "transcript_\(cleaned.lowercased())",
                    name: cleaned,
                    quantity: 1,
                    modifierNames: [], negations: [],
                    course: .entree,
                    seatNumber: activeSeatNumber,
                    notes: "", confidence: 0.5, hasAllergyFlag: false
                )
                item.seatNumber = activeSeatNumber
                draft.addItem(item)
            }
        }

        refreshUpsells()
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
