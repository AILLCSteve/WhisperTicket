import AVFoundation
import Combine

final class AudioCaptureService: AudioCaptureServiceProtocol {
    private(set) var isRecording = false
    private(set) var noiseLevel: Float = 0.0

    private let audioEngine = AVAudioEngine()
    private let bufferSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private let interruptionSubject = PassthroughSubject<Void, Never>()
    private var interruptionObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    func startCapture() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        registerInterruptionObserver()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            // Copy the buffer before sending — the engine can reuse the internal PCM
            // memory before downstream Combine subscribers finish processing it.
            if let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
               let src = buffer.floatChannelData,
               let dst = copy.floatChannelData {
                copy.frameLength = buffer.frameLength
                let byteCount = Int(buffer.frameLength) * MemoryLayout<Float>.size
                for ch in 0..<Int(buffer.format.channelCount) {
                    memcpy(dst[ch], src[ch], byteCount)
                }
                self.bufferSubject.send(copy)
            }
            self.updateNoiseLevel(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }

    func stopCapture() {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRecording = false
        noiseLevel = 0.0
    }

    func audioBufferPublisher() -> AnyPublisher<AVAudioPCMBuffer, Never> {
        bufferSubject.eraseToAnyPublisher()
    }

    func interruptionPublisher() -> AnyPublisher<Void, Never> {
        interruptionSubject.eraseToAnyPublisher()
    }

    // MARK: - Private

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
                self.stopCapture()
                self.interruptionSubject.send()
            }
        }
    }

    private func updateNoiseLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        var rms: Float = 0
        for i in 0..<frameCount { rms += channelData[i] * channelData[i] }
        rms = sqrt(rms / Float(frameCount))
        DispatchQueue.main.async { self.noiseLevel = min(rms * 10, 1.0) }
    }
}
