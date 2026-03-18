import Speech
import AVFoundation
import Combine

final class SFSpeechTranscriptionService: TranscriptionServiceProtocol {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let transcriptionSubject = PassthroughSubject<TranscriptionSegment, Never>()
    private var cancellables = Set<AnyCancellable>()

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
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let result {
                let segment = TranscriptionSegment(
                    text: result.bestTranscription.formattedString,
                    isFinal: result.isFinal
                )
                self?.transcriptionSubject.send(segment)
            }
            if error != nil || result?.isFinal == true {
                self?.stopTranscribing()
            }
        }

        audioPublisher
            .sink { [weak request] buffer in request?.append(buffer) }
            .store(in: &cancellables)
    }

    func stopTranscribing() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        cancellables.removeAll()
    }
}

enum TranscriptionError: Error {
    case recognizerUnavailable
    case permissionDenied
}
