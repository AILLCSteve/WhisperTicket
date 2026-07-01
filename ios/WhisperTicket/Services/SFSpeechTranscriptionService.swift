import Speech
import AVFoundation
import os

/// Transcribes a complete audio file in one shot using on-device speech
/// recognition. No streaming, no partial results, no session state to reconcile —
/// which is exactly why it can't erase or lose text. One file in, one transcript
/// out.
final class SFSpeechTranscriptionService: TranscriptionServiceProtocol {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let log = Logger(subsystem: "com.whisperticket.app", category: "ASR")

    static func requestPermission(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = false      // only the final result
        request.requiresOnDeviceRecognition = true       // no 60s server limit

        log.debug("transcribe file=\(fileURL.lastPathComponent, privacy: .public)")

        // Bridge the callback API to async, resuming exactly once.
        final class Once { var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                guard !once.done else { return }
                once.done = true
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }
}

enum TranscriptionError: Error {
    case recognizerUnavailable
    case permissionDenied
}
