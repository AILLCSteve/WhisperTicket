import Foundation
import Observation
import Combine

@Observable
final class LiveSessionViewModel {
    var transcript: String = ""
    var draft: TicketDraft
    var upsellSuggestions: [UpsellSuggestionResult] = []
    var isRecording = false
    var noiseLevel: Float = 0.0
    var showNoisyEnvironmentWarning = false
    var repeatBackText: String = ""
    var showRepeatBack = false
    var detectedMacro: VoiceMacro? = nil
    var errorMessage: String? = nil
    var allergyItemsPendingConfirm: [DraftItem] = []

    private let audioCapture: AudioCaptureServiceProtocol
    private let transcriptionService: TranscriptionServiceProtocol
    private let parser: OrderParserProtocol
    private let menuStore: MenuStoreProtocol
    private let upsellEngine: UpsellEngineProtocol
    private var cancellables = Set<AnyCancellable>()

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
            try audioCapture.startCapture()
            let audioPublisher = audioCapture.audioBufferPublisher()
            try transcriptionService.startTranscribing(audioPublisher: audioPublisher)
            draft.consumedCursor = 0  // reset cursor for new recording session
            isRecording = true

            transcriptionService.transcriptionPublisher()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] segment in self?.handleTranscriptionSegment(segment) }
                .store(in: &cancellables)

            // Noise level polling
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
        transcriptionService.stopTranscribing()
        isRecording = false
        cancellables.removeAll()
        noiseLevel = 0.0
        showNoisyEnvironmentWarning = false
    }

    func triggerRepeatBack() {
        repeatBackText = parser.repeatBackSummary(for: draft)
        showRepeatBack = true
    }

    func confirmAllergyItem(_ item: DraftItem) {
        allergyItemsPendingConfirm.removeAll { $0.id == item.id }
    }

    func removeItem(_ item: DraftItem) {
        draft.items.removeAll { $0.id == item.id }
        refreshUpsells()
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
        transcript = segment.text

        // Always check for macros on every segment
        if let macro = parser.detectMacro(in: segment.text) {
            detectedMacro = macro
        }

        // Only update the ticket draft on final segments to avoid cursor confusion:
        // SFSpeechRecognizer replaces the entire transcript on each partial result,
        // so advancing the cursor on partials causes missed/duplicate item parses.
        guard segment.isFinal, let menu = menuStore.menu else { return }

        let updatedDraft = parser.parseDraft(transcript: segment.text, existingDraft: draft, menu: menu)
        draft = updatedDraft

        // Allergy guardrail: surface new allergy items needing confirmation
        let existingIds = Set(allergyItemsPendingConfirm.map { $0.id })
        let newAllergyItems = draft.items.filter { $0.hasAllergyFlag && !existingIds.contains($0.id) }
        allergyItemsPendingConfirm.append(contentsOf: newAllergyItems)

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
