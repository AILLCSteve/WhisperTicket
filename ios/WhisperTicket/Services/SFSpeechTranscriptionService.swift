import Speech
import AVFoundation
import Combine
import os

/// On-device streaming transcription that records **continuously** until the
/// caller stops it — like a plain audio recorder, no timers and no
/// silence-triggered teardown.
///
/// ## Why it's built this way
/// The previous design tore down and recreated the recognition task every time
/// `SFSpeechRecognizer` fired `isFinal` (which it does after a pause). That
/// restart dropped audio and, via shared mutable state touched by late callbacks
/// from dead tasks, erased text that had already been spoken — the "transcript
/// reset on pause" bug.
///
/// This version keeps a single recognition task alive for the whole session.
/// `requiresOnDeviceRecognition = true` removes the 60-second server limit, so a
/// single task can run indefinitely. If the recognizer *does* end a segment on
/// its own (endpointing) or errors, we transparently continue a new segment
/// **without losing committed text**, and a monotonic `generation` id makes any
/// late callback from a superseded task a no-op. The emitted transcript therefore
/// only ever grows within a session.
final class SFSpeechTranscriptionService: TranscriptionServiceProtocol {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let transcriptionSubject = PassthroughSubject<TranscriptionSegment, Never>()
    private let log = Logger(subsystem: "com.whisperticket.app", category: "ASR")

    /// Text confirmed by segments that have already ended, seeded with the seat's
    /// prior transcript. Only ever grows during a session — the single source of
    /// truth the emitted transcript is built from.
    private var committedText = ""
    /// Longest transcript seen in the CURRENT task (reset per task). Guards against
    /// an `isFinal` result that arrives shorter than an earlier partial from
    /// erasing words. Only the current-generation callback ever touches it, so
    /// there is no cross-task contamination.
    private var taskHighWater = ""
    /// Bumped every time a task starts or the session stops, so callbacks from a
    /// superseded/cancelled task are ignored (prevents dead tasks from clobbering
    /// state after a continuation restart).
    private var generation = 0
    private var isSessionActive = false
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

    func startTranscribing(audioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>, seed: String) throws {
        committedText = seed
        isSessionActive = true
        log.debug("startTranscribing seed=\(seed.count, privacy: .public) chars")

        // Subscribe once for the whole session. The closure always appends to the
        // current request, so a continuation restart never needs to re-subscribe.
        audioCancellable = audioPublisher.sink { [weak self] buffer in
            self?.recognitionRequest?.append(buffer)
        }

        try beginTask()
    }

    private func beginTask() throws {
        guard isSessionActive else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request

        generation &+= 1
        let myGen = generation
        let base = committedText
        taskHighWater = ""
        log.debug("beginTask gen=\(myGen, privacy: .public) base=\(base.count, privacy: .public) chars")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.isSessionActive, myGen == self.generation else { return }

            if let result {
                let current = result.bestTranscription.formattedString
                // Never shrink within a task: keep the longest partial seen so an
                // isFinal that arrives shorter can't erase already-shown words.
                if current.count > self.taskHighWater.count { self.taskHighWater = current }
                let full = Self.join(base, self.taskHighWater)
                if !full.isEmpty {
                    self.transcriptionSubject.send(TranscriptionSegment(text: full, isFinal: result.isFinal))
                }
                if result.isFinal {
                    // The recognizer ended this segment on its own. Commit its text
                    // and immediately continue a new segment so recording never
                    // actually stops until the user stops it.
                    if !self.taskHighWater.isEmpty { self.committedText = full }
                    self.continueSegment()
                    return
                }
            }

            if error != nil {
                self.log.debug("ASR error — continuing; committed=\(self.committedText.count, privacy: .public)")
                self.continueSegment()
            }
        }
    }

    /// Continue transcription after the recognizer ended a segment, without losing
    /// any committed text. This is the ONLY restart path — there is no
    /// silence-timer restart. Bumping `generation` (via beginTask) plus cancelling
    /// the old task ensures no stale callback can run after this point.
    private func continueSegment() {
        guard isSessionActive else { return }
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isSessionActive else { return }
            try? self.beginTask()
        }
    }

    /// Join a committed prefix and a live suffix with a single space, tolerating
    /// either side being empty.
    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return "\(a) \(b)"
    }

    func endAudioInput() {
        // Seal the session so no continuation restart can start on the now-dead
        // audio engine. The existing task still drains its final result before
        // stopTranscribing() cleans up.
        isSessionActive = false
        recognitionRequest?.endAudio()
    }

    func stopTranscribing() {
        isSessionActive = false
        generation &+= 1  // invalidate any in-flight task callback
        audioCancellable?.cancel()
        audioCancellable = nil
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        committedText = ""
        taskHighWater = ""
    }
}

enum TranscriptionError: Error {
    case recognizerUnavailable
    case permissionDenied
}
