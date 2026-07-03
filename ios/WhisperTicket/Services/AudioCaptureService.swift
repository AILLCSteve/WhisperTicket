import AVFoundation
import Combine

/// Records microphone audio to files, continuously, until told to stop — with
/// SILENCE-GATED SEGMENT ROTATION.
///
/// WHY ROTATION EXISTS (do not remove):
/// `SFSpeechRecognizer` — streaming OR file-based — runs an utterance endpointer
/// that RESETS its transcription context when it encounters a long silence. A
/// single file containing "phrase … [5s pause] … phrase" will come back with only
/// the post-pause text. See memory/debug_history.md (2026-07 entries). The only
/// reliable contract with SFSpeech is: never hand it audio containing a long
/// internal pause.
///
/// So: while recording, we watch the meter. When the user has spoken and then
/// gone quiet for `silenceRotationThreshold`, we close the current file, hand it
/// to `onSegmentReady`, and IMMEDIATELY start a new file. The rotation gap
/// (~10–50 ms) happens during silence, so no speech is ever lost. Recording has
/// NO length limit — it just produces more segments.
///
/// Segments are transcribed while recording continues, which also makes the
/// final "Processing…" step near-instant for long orders.
final class AudioCaptureService: NSObject, AudioCaptureServiceProtocol {
    private(set) var isRecording = false
    private(set) var noiseLevel: Float = 0.0

    /// Called on an arbitrary thread each time a completed segment file is
    /// finalized (rotation). NOT called for the final segment — that one is
    /// returned by `stopRecording()`. Caller owns the file.
    var onSegmentReady: ((URL) -> Void)?

    // MARK: - Tuning (all values in seconds unless noted)

    /// Meter level (0…1) at/above which we consider the user to be speaking.
    /// With the -50 dBFS floor mapping below, 0.18 ≈ -41 dBFS — comfortably above
    /// recorder self-noise, below quiet speech. Tune on device if needed.
    private let speechLevelThreshold: Float = 0.18

    /// Sustained quiet required (after speech has been heard) before rotating.
    /// Must be shorter than SFSpeech's internal endpoint (~2s on-device) so we
    /// split BEFORE the recognizer would have reset, but long enough that normal
    /// inter-word gaps never trigger it.
    private let silenceRotationThreshold: TimeInterval = 1.3

    /// Once a segment is older than this, rotate on a much shorter dip. Keeps
    /// segments bounded even for continuous fast talkers, without ever cutting
    /// mid-word (we still require a dip below the speech threshold).
    private let longSegmentAge: TimeInterval = 45.0
    private let longSegmentDipThreshold: TimeInterval = 0.35

    /// Never rotate a segment that contains no speech yet (nothing to transcribe;
    /// avoids spawning empty files while the user thinks before talking).
    // (implemented via `speechDetectedInSegment` below)

    // MARK: - Private state

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentFileURL: URL?
    private var segmentStartedAt: Date = .distantPast
    private var speechDetectedInSegment = false
    private var quietSince: Date?

    private let interruptionSubject = PassthroughSubject<Void, Never>()
    private var interruptionObserver: NSObjectProtocol?

    // MARK: - AudioCaptureServiceProtocol

    func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        registerInterruptionObserver()
        try startNewSegment()
        isRecording = true

        // Poll metering for the live waveform AND the rotation gate.
        // 20 Hz keeps rotation latency tight without measurable cost.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func stopRecording() -> URL? {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
        recorder = nil
        isRecording = false
        noiseLevel = 0.0
        quietSince = nil

        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        // Leave the session active; deactivating here can clip the tail of the file.
        let url = currentFileURL
        currentFileURL = nil
        // If the final segment never heard speech, still return it — the
        // transcription layer skips empty results harmlessly.
        return url
    }

    func interruptionPublisher() -> AnyPublisher<Void, Never> {
        interruptionSubject.eraseToAnyPublisher()
    }

    // MARK: - Segment lifecycle

    private func startNewSegment() throws {
        // Unique file per segment so segments never overwrite each other.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperticket_\(UUID().uuidString).m4a")
        currentFileURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            throw TranscriptionError.recognizerUnavailable
        }
        self.recorder = recorder
        segmentStartedAt = Date()
        speechDetectedInSegment = false
        quietSince = nil
    }

    /// Close the current segment mid-recording (during a pause), hand it off,
    /// and start the next one. If the new recorder fails to start, we surface it
    /// as an interruption so the ViewModel finalizes what we have — never lose
    /// captured audio silently.
    private func rotateSegment() {
        guard isRecording, let finishedURL = currentFileURL else { return }
        recorder?.stop()
        recorder = nil
        currentFileURL = nil

        onSegmentReady?(finishedURL)

        do {
            try startNewSegment()
        } catch {
            isRecording = false
            interruptionSubject.send()
        }
    }

    // MARK: - Metering + rotation gate

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // averagePower is in dBFS (-160 silent ... 0 loudest). Map to 0...1.
        let power = recorder.averagePower(forChannel: 0)
        let normalized = max(0, (power + 50) / 50)  // -50 dB floor
        noiseLevel = min(1, normalized)

        let now = Date()

        if noiseLevel >= speechLevelThreshold {
            speechDetectedInSegment = true
            quietSince = nil
            return
        }

        // Below speech level. Only consider rotating if this segment actually
        // contains speech — otherwise there is nothing worth transcribing yet.
        guard speechDetectedInSegment else { return }

        if quietSince == nil { quietSince = now }
        let quietDuration = now.timeIntervalSince(quietSince ?? now)
        let segmentAge = now.timeIntervalSince(segmentStartedAt)
        let required = segmentAge > longSegmentAge
            ? longSegmentDipThreshold
            : silenceRotationThreshold

        if quietDuration >= required {
            rotateSegment()
        }
    }

    // MARK: - Interruptions

    private func registerInterruptionObserver() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            if type == .began {
                // Do NOT call stopRecording() here — the ViewModel drives the
                // finalize path so the last file is transcribed, not dropped.
                self.interruptionSubject.send()
            }
        }
    }
}
