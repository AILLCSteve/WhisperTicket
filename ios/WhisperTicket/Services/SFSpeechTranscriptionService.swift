import Speech
import AVFoundation
import os

/// Transcribes a complete audio file using on-device speech recognition, with
/// two protections the previous implementation lacked:
///
/// 1. RESET STITCHING (the critical one). `SFSpeechRecognizer` — even on a FILE —
///    runs an utterance endpointer. When it encounters a long internal silence,
///    it can reset its transcription context; text after the reset no longer
///    contains text from before it. With `shouldReportPartialResults = false`,
///    the single "final" result then covers ONLY the last utterance — which is
///    exactly the "only the last phrase survives" bug. This implementation
///    enables partial results purely as an OBSERVATION channel: it watches the
///    stream of hypotheses, detects context resets, commits the pre-reset
///    high-water text, and stitches every epoch together. Nothing about this is
///    "streaming ASR" in the old sense — the audio is a finished file; partials
///    are just how we see all of the recognizer's output instead of only its
///    last segment.
///
/// 2. TIMEOUT. The old continuation could hang forever if the recognizer never
///    delivered a final (flagged in debug_history as a latent risk). We now
///    resolve with the best text seen so far after a duration-scaled deadline.
///
/// NOTE: with segment rotation in AudioCaptureService, files handed to this
/// service should rarely contain a long pause at all. The stitching here is the
/// independent second layer of defense (e.g. loud rooms where the meter never
/// drops below the rotation threshold, so a pause reaches the recognizer anyway).
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
        // Partial results ON — as an observation channel for reset stitching,
        // NOT for live UI. See header comment. Do not set this back to false:
        // false = you only ever see the recognizer's LAST utterance segment.
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(iOS 16.0, *) {
            request.addsPunctuation = false   // parser expects raw text; keep stable
        }

        let duration = Self.audioDuration(of: fileURL)
        // On-device recognition is faster than realtime; 2.5x + floor is generous.
        let timeoutSeconds = max(15.0, duration * 2.5)

        log.debug("transcribe file=\(fileURL.lastPathComponent, privacy: .public) dur=\(duration, format: .fixed(precision: 2)) timeout=\(timeoutSeconds, format: .fixed(precision: 1))")

        let stitcher = TranscriptStitcher()
        // State shared between recognizer callbacks (background queue) and the
        // timeout task. Guarded by `lock`; continuation resumed exactly once.
        final class Box {
            var done = false
            var task: SFSpeechRecognitionTask?
            let lock = NSLock()
        }
        let box = Box()

        let text: String = try await withCheckedThrowingContinuation { continuation in
            func finish(_ result: Result<String, Error>) {
                box.lock.lock()
                defer { box.lock.unlock() }
                guard !box.done else { return }
                box.done = true
                box.task?.cancel()
                switch result {
                case .success(let s): continuation.resume(returning: s)
                case .failure(let e): continuation.resume(throwing: e)
                }
            }

            box.task = recognizer.recognitionTask(with: request) { [log] result, error in
                if let result {
                    stitcher.observe(result.bestTranscription.formattedString)
                    if result.isFinal {
                        log.debug("isFinal received; stitched=\(stitcher.stitched.count, privacy: .public) chars")
                        finish(.success(stitcher.stitched))
                        return
                    }
                }
                if let error {
                    let stitched = stitcher.stitched
                    if !stitched.isEmpty {
                        // The recognizer errored AFTER producing text (silence
                        // timeout, kAFAssistantErrorDomain 209/216, etc). The
                        // text we have is real — return it instead of throwing.
                        log.error("recognizer error after text: \(error.localizedDescription, privacy: .public) — returning \(stitched.count) stitched chars")
                        finish(.success(stitched))
                    } else {
                        log.error("recognizer error, no text: \(error.localizedDescription, privacy: .public)")
                        finish(.failure(error))
                    }
                }
            }

            // Watchdog: never hang the "Processing…" spinner.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(.success(stitcher.stitched))   // best-effort; may be ""
            }
        }

        return text
    }

    private static func audioDuration(of url: URL) -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let seconds = CMTimeGetSeconds(asset.duration)
        return seconds.isFinite ? seconds : 0
    }
}

/// Accumulates recognizer hypotheses across CONTEXT RESETS.
///
/// Model: the recognizer emits a stream of hypotheses. Within one "epoch"
/// (utterance context), each hypothesis revises the previous one — it may grow,
/// or shrink slightly as words are re-scored. When the endpointer resets, the
/// next hypothesis is a fresh string that no longer relates to the previous one
/// (dramatically shorter and not a prefix-revision). On reset: commit the
/// previous epoch's high-water text and start a new epoch. `stitched` is always
/// committed epochs + current epoch, in order — nothing before a pause can be lost.
final class TranscriptStitcher {
    private let lock = NSLock()
    private var committed: [String] = []
    private var epochBest: String = ""

    var stitched: String {
        lock.lock(); defer { lock.unlock() }
        return (committed + (epochBest.isEmpty ? [] : [epochBest]))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func observe(_ hypothesis: String) {
        let text = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }   // empty hypotheses never regress state
        lock.lock(); defer { lock.unlock() }

        if epochBest.isEmpty {
            epochBest = text
            return
        }

        if isReset(new: text, best: epochBest) {
            committed.append(epochBest)
            epochBest = text
            return
        }

        // Same epoch: keep the high-water hypothesis. A shorter same-epoch
        // hypothesis is a down-revision (e.g. "I want a steak" → "I want") —
        // never let it erase the longer text (this exact down-revision is what
        // broke the 2026-05 lastNonEmptyText fix).
        if text.count >= epochBest.count {
            epochBest = text
        }
    }

    /// Reset heuristic: the new hypothesis is much shorter than what this epoch
    /// already produced AND is not simply a truncated revision of it (i.e. the
    /// old text does not start with the new text). "some mashed potatoes" after
    /// "I want a steak and" → reset. "I want" after "I want a steak" → revision.
    private func isReset(new: String, best: String) -> Bool {
        guard new.count < best.count / 2 else { return false }
        return !best.lowercased().hasPrefix(new.lowercased())
    }
}

enum TranscriptionError: Error {
    case recognizerUnavailable
    case permissionDenied
}
