import AVFoundation
import Combine

final class AudioCaptureService: AudioCaptureServiceProtocol {
    private(set) var isRecording = false
    private(set) var noiseLevel: Float = 0.0

    private let audioEngine = AVAudioEngine()
    private let bufferSubject = PassthroughSubject<AVAudioPCMBuffer, Never>()
    private var cancellables = Set<AnyCancellable>()

    func startCapture() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.bufferSubject.send(buffer)
            self?.updateNoiseLevel(buffer: buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true
    }

    func stopCapture() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRecording = false
        noiseLevel = 0.0
    }

    func audioBufferPublisher() -> AnyPublisher<AVAudioPCMBuffer, Never> {
        bufferSubject.eraseToAnyPublisher()
    }

    // Low complexity: noise level detection
    private func updateNoiseLevel(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)
        var rms: Float = 0
        for i in 0..<frameCount { rms += channelData[i] * channelData[i] }
        rms = sqrt(rms / Float(frameCount))
        DispatchQueue.main.async { self.noiseLevel = min(rms * 10, 1.0) }
    }
}
