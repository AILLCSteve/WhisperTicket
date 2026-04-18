import Speech
import AVFoundation
import Combine

final class SFSpeechTranscriptionService: TranscriptionServiceProtocol {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let transcriptionSubject = PassthroughSubject<TranscriptionSegment, Never>()

    // Auto-restart state
    private var accumulatedBase = ""
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

        // Capture the base text at the moment this task starts so the closure
        // always appends to the correct prefix even across restarts.
        let base = accumulatedBase

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let currentText = result.bestTranscription.formattedString
                let fullText = base.isEmpty ? currentText : "\(base) \(currentText)"
                let segment = TranscriptionSegment(text: fullText, isFinal: result.isFinal)
                self.transcriptionSubject.send(segment)

                if result.isFinal {
                    if self.isSessionActive {
                        // Accumulate and restart a new recognition task.
                        self.accumulatedBase = fullText
                        self.recognitionRequest = nil
                        self.recognitionTask = nil
                        try? self.beginRecognitionTask()
                    }
                    // If !isSessionActive, stopTranscribing() already cleaned up.
                }
            }

            if let error, !self.isSessionActive {
                // Only clean up on error when the session has been explicitly stopped;
                // transient errors during an active session are handled by the restart path.
                _ = error // suppress unused-variable warning
                self.stopTranscribing()
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
    }
}

enum TranscriptionError: Error {
    case recognizerUnavailable
    case permissionDenied
}
