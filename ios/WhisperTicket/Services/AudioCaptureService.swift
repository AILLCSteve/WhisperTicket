import AVFoundation
import Combine

/// Records microphone audio to a file, continuously, until told to stop. There is
/// no live recognition here — capture is just capture. Recorded audio in a file
/// cannot be "lost" the way a streaming recognition session can, which is the
/// whole point of the record-then-transcribe design.
final class AudioCaptureService: NSObject, AudioCaptureServiceProtocol {
    private(set) var isRecording = false
    private(set) var noiseLevel: Float = 0.0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentFileURL: URL?
    private let interruptionSubject = PassthroughSubject<Void, Never>()
    private var interruptionObserver: NSObjectProtocol?

    func startRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        registerInterruptionObserver()

        // Unique file per recording so subsequent recordings never overwrite.
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
        isRecording = true

        // Poll metering for the live waveform.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.updateMeter()
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

        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        // Leave the session active; deactivating here can clip the tail of the file.
        let url = currentFileURL
        currentFileURL = nil
        return url
    }

    func interruptionPublisher() -> AnyPublisher<Void, Never> {
        interruptionSubject.eraseToAnyPublisher()
    }

    // MARK: - Private

    private func updateMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // averagePower is in dBFS (-160 silent ... 0 loudest). Map to 0...1.
        let power = recorder.averagePower(forChannel: 0)
        let normalized = max(0, (power + 50) / 50)  // -50 dB floor
        noiseLevel = min(1, normalized)
    }

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
                _ = self.stopRecording()
                self.interruptionSubject.send()
            }
        }
    }
}
