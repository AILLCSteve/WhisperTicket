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
    /// The last non-empty full transcript received (partial or final) in the current task.
    /// Guards against isFinal firing with an empty/degraded result after a valid partial
    /// was already displayed — prevents the transcript from visually blanking mid-session.
    private var lastNonEmptyText = ""
    private var isSessionActive = false
    private var storedAudioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>?
    private var audioCancellable: AnyCancellable?

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
        storedAudioPublisher = audioPublisher
        accumulatedBase = ""
        lastNonEmptyText = ""
        isSessionActive = true
        try beginRecognitionTask()
    }

    private func beginRecognitionTask() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }
        guard storedAudioPublisher != nil else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request

        // Snapshot base at task-start time. Immutable for this closure's lifetime.
        let base = accumulatedBase

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.isSessionActive else { return }

            // Handle speech result first.
            if let result {
                let currentText = result.bestTranscription.formattedString
                let computed = base.isEmpty ? currentText : "\(base) \(currentText)"

                // Never regress: if isFinal fires with empty/degraded text (e.g., on
                // silence timeout) keep the last valid text already shown in the UI.
                let textToSend: String
                if computed.isEmpty {
                    textToSend = self.lastNonEmptyText
                } else {
                    textToSend = computed
                    self.lastNonEmptyText = computed
                }

                self.transcriptionSubject.send(TranscriptionSegment(text: textToSend, isFinal: result.isFinal))

                if result.isFinal {
                    // Use lastNonEmptyText as the new accumulated base so the next task
                    // starts from the best text we've ever seen, not isFinal's potentially
                    // empty result.
                    let preserved = self.lastNonEmptyText
                    self.accumulatedBase = preserved
                    self.lastNonEmptyText = ""
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                    try? self.beginRecognitionTask()
                    return  // Don't fall through — restart already handled.
                }
            }

            // Handle errors during active sessions (e.g., kAFAssistantErrorDomain 209
            // = silence timeout, or recognizer internal error). Restart immediately to
            // keep the session alive — do NOT ignore errors as that leaves the audio
            // appended to a dead request with no transcription output.
            if let _ = error {
                if !self.lastNonEmptyText.isEmpty {
                    self.accumulatedBase = self.lastNonEmptyText
                }
                self.lastNonEmptyText = ""
                self.recognitionRequest = nil
                self.recognitionTask = nil
                try? self.beginRecognitionTask()
            }
        }

        audioCancellable?.cancel()
        audioCancellable = storedAudioPublisher?.sink { [weak request] buffer in
            request?.append(buffer)
        }
    }

    func endAudioInput() {
        // Seal immediately: prevents isFinal from restarting on dead audio.
        // Does NOT cancel the task so the drain callback can still deliver the
        // final partial result before stopTranscribing() cleans up.
        isSessionActive = false
        storedAudioPublisher = nil
        audioCancellable?.cancel()
        audioCancellable = nil
        recognitionRequest?.endAudio()
    }

    func stopTranscribing() {
        isSessionActive = false
        storedAudioPublisher = nil
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
