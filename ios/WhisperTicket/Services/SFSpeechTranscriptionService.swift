import Speech
import AVFoundation
import Combine

final class SFSpeechTranscriptionService: TranscriptionServiceProtocol {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let transcriptionSubject = PassthroughSubject<TranscriptionSegment, Never>()

    // MARK: - Accumulation state

    /// Text confirmed by all completed recognition tasks so far in this session.
    private var accumulatedBase = ""
    /// Last non-empty full transcript seen in the current task — guards against
    /// isFinal firing with an empty/degraded result after valid text was shown.
    private var lastNonEmptyText = ""
    private var isSessionActive = false

    // MARK: - Audio relay
    //
    // A single subscription to the upstream audio publisher persists for the
    // entire recording session. Each buffer is delivered to whatever
    // `recognitionRequest` is current at delivery time. This means recognition
    // task restarts (after isFinal or error) never create an audio gap — the
    // PassthroughSubject always has an active subscriber so no frames are lost.
    private var audioCancellable: AnyCancellable?

    // Guards against rapid-restart loops when a new task fires isFinal
    // immediately because it got silence at the start (e.g., during engine warm-up).
    private var lastRestartDate: Date = .distantPast

    static func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    func transcriptionPublisher() -> AnyPublisher<TranscriptionSegment, Never> {
        transcriptionSubject.eraseToAnyPublisher()
    }

    func startTranscribing(audioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>) throws {
        accumulatedBase = ""
        lastNonEmptyText = ""
        isSessionActive = true

        // Subscribe ONCE. The closure always reads self?.recognitionRequest so
        // hot-swapping requests (on task restart) redirects audio without cancelling
        // the upstream subscription — no frames dropped at transition boundaries.
        audioCancellable = audioPublisher.sink { [weak self] buffer in
            self?.recognitionRequest?.append(buffer)
        }

        try beginRecognitionTask()
    }

    private func beginRecognitionTask() throws {
        guard isSessionActive else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        // Hot-swap: point the persistent audio relay at the new request BEFORE
        // cancelling the old task, so audio is continuous across the boundary.
        self.recognitionRequest = request
        lastRestartDate = Date()

        // Snapshot base at task-start time — immutable for this closure's lifetime.
        let base = accumulatedBase

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.isSessionActive else { return }

            if let result {
                let currentText = result.bestTranscription.formattedString
                let computed: String
                if base.isEmpty {
                    computed = currentText
                } else if currentText.isEmpty {
                    computed = base
                } else {
                    computed = "\(base) \(currentText)"
                }

                // Never regress: if isFinal fires with empty/degraded text keep the
                // last valid transcript already shown in the UI.
                let textToSend: String
                if computed.isEmpty {
                    textToSend = self.lastNonEmptyText
                } else {
                    textToSend = computed
                    self.lastNonEmptyText = computed
                }

                self.transcriptionSubject.send(TranscriptionSegment(text: textToSend, isFinal: result.isFinal))

                if result.isFinal {
                    let preserved = self.lastNonEmptyText
                    // Only advance the accumulated base when we actually have text.
                    // An empty preserved would erase text from previous tasks.
                    if !preserved.isEmpty {
                        self.accumulatedBase = preserved
                    }
                    self.lastNonEmptyText = ""
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                    self.scheduleRestart()
                    return
                }
            }

            if let _ = error {
                if !self.lastNonEmptyText.isEmpty {
                    self.accumulatedBase = self.lastNonEmptyText
                }
                self.lastNonEmptyText = ""
                self.recognitionRequest = nil
                self.recognitionTask = nil
                self.scheduleRestart()
            }
        }
    }

    // Schedules a restart with a back-off when the task fired isFinal too quickly
    // (< 200 ms after starting), which indicates the recognizer got silence at
    // the boundary and would loop immediately without a delay.
    private func scheduleRestart() {
        guard isSessionActive else { return }
        let elapsed = Date().timeIntervalSince(lastRestartDate)
        let delay = elapsed < 0.2 ? 0.25 : 0.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isSessionActive else { return }
            try? self.beginRecognitionTask()
        }
    }

    func endAudioInput() {
        // Seal the session so scheduled restarts are no-ops after this point.
        // Do NOT cancel audioCancellable here — we want the final partial result
        // to drain through the existing task before stopTranscribing() cleans up.
        isSessionActive = false
        recognitionRequest?.endAudio()
    }

    func stopTranscribing() {
        isSessionActive = false
        audioCancellable?.cancel()
        audioCancellable = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        accumulatedBase = ""
        lastNonEmptyText = ""
    }
}

enum TranscriptionError: Error {
    case recognizerUnavailable
    case permissionDenied
}
