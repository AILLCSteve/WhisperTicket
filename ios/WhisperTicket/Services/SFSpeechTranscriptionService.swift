import Speech
import AVFoundation
import Combine
import os

/// On-device streaming transcription with a single source of truth for the
/// full session transcript.
///
/// ## Why this design
/// `SFSpeechRecognizer` restarts recognition tasks mid-session (after a pause it
/// fires `isFinal`; on silence/timeout it errors). Naively, each restarted task
/// only transcribes audio recorded *after* the restart, so the text spoken before
/// the pause disappears — the classic "transcript reset" bug.
///
/// This service guarantees the emitted transcript **never goes backward**:
///
/// - `committedText` holds everything confirmed by prior tasks (seeded with any
///   transcript that already existed for the seat). It only ever grows.
/// - `taskBest` is the longest partial seen in the *current* task (a per-task
///   high-water mark), so an isFinal that arrives empty or shorter than an earlier
///   partial can never erase text that was already displayed.
/// - The emitted transcript is always `committedText (+ " " + taskBest)`.
///
/// Because the service owns the entire transcript, the ViewModel simply displays
/// what it emits — there is no second accumulation layer to drift out of sync.
final class SFSpeechTranscriptionService: TranscriptionServiceProtocol {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let transcriptionSubject = PassthroughSubject<TranscriptionSegment, Never>()
    private let log = Logger(subsystem: "com.whisperticket.app", category: "ASR")

    // MARK: - Accumulation state (single source of truth)

    /// Everything confirmed by completed recognition tasks in this session,
    /// including the seed transcript passed at start. Only ever grows.
    private var committedText = ""
    /// Longest partial transcript seen in the *current* task — a per-task
    /// high-water mark. Guards against isFinal firing empty/degraded after valid
    /// text was already shown. Reset to "" when a new task begins.
    private var taskBest = ""
    private var isSessionActive = false

    // MARK: - Audio relay
    //
    // A single subscription to the upstream audio publisher persists for the
    // entire recording session. Each buffer is delivered to whatever
    // `recognitionRequest` is current at delivery time, so task restarts never
    // require re-subscribing to audio.
    private var audioCancellable: AnyCancellable?

    // Timestamp of the last task start, used to back off if a task fires isFinal
    // almost immediately (silence at the boundary) to avoid a tight restart loop.
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

    func startTranscribing(audioPublisher: AnyPublisher<AVAudioPCMBuffer, Never>, seed: String) throws {
        committedText = seed
        taskBest = ""
        isSessionActive = true
        log.debug("startTranscribing seed=\(seed.count, privacy: .public) chars")

        // Subscribe ONCE. The closure always reads self?.recognitionRequest so
        // hot-swapping requests (on task restart) redirects audio without
        // cancelling the upstream subscription — no re-subscription churn.
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

        self.recognitionRequest = request
        lastRestartDate = Date()
        taskBest = ""

        // Snapshot the committed prefix for this task's lifetime.
        let base = committedText
        log.debug("beginRecognitionTask base=\(base.count, privacy: .public) chars")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.isSessionActive else { return }

            if let result {
                let current = result.bestTranscription.formattedString
                // Per-task high-water mark: never shrink within a task.
                if current.count > self.taskBest.count {
                    self.taskBest = current
                }
                let full = Self.join(base, self.taskBest)

                self.transcriptionSubject.send(TranscriptionSegment(text: full, isFinal: result.isFinal))

                if result.isFinal {
                    self.commitAndRestart(base: base)
                    return
                }
            }

            if error != nil {
                self.log.debug("recognition error — restarting; committed=\(self.committedText.count, privacy: .public)")
                self.commitAndRestart(base: base)
            }
        }
    }

    /// Fold the current task's best text into the permanent committed prefix and
    /// schedule the next task. `committedText` only ever grows, so no prior text
    /// can be lost across the restart boundary.
    private func commitAndRestart(base: String) {
        if !taskBest.isEmpty {
            committedText = Self.join(base, taskBest)
        }
        taskBest = ""
        recognitionRequest = nil
        recognitionTask = nil
        scheduleRestart()
    }

    /// Join a committed prefix and a live suffix with a single space, tolerating
    /// either side being empty.
    private static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return "\(a) \(b)"
    }

    // Schedules a restart with a back-off when the task fired isFinal too quickly
    // (< 200 ms after starting), which indicates the recognizer got silence at the
    // boundary and would loop immediately without a delay. Because isFinal fires on
    // silence, the brief gap loses no real speech.
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
        committedText = ""
        taskBest = ""
    }
}

enum TranscriptionError: Error {
    case recognizerUnavailable
    case permissionDenied
}
