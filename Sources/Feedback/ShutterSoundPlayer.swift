import AVFoundation
import os

/// The Edition's leaf-shutter sound (Slice 3 §8): a pre-loaded buffer on an `AVAudioPlayerNode`,
/// triggered at `willBeginCapture` for the lowest latency. The audio session is `.ambient` and
/// mixes with others, so it respects the silent switch and never interrupts music. In regions where
/// iOS plays its own shutter sound, that sound plays as well.
final class ShutterSoundPlayer: @unchecked Sendable {

    private let lock = NSLock()
    private let logger = Logger(subsystem: "ManualCameraApp", category: "Sound")
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffer: AVAudioPCMBuffer?
    private var volume: ShutterSoundVolume = .low

    /// Loads the sound and starts the engine (off the main thread).
    func prepare(volume: ShutterSoundVolume) {
        setVolume(volume)
        lock.lock()
        defer { lock.unlock() }
        guard engine == nil, volume != .off else { return }
        guard let url = Bundle.main.url(forResource: "LeafShutter", withExtension: "caf") else {
            logger.error("LeafShutter.caf missing from the bundle")
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            let file = try AVAudioFile(forReading: url)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
            try file.read(into: pcm)
            let newEngine = AVAudioEngine()
            let node = AVAudioPlayerNode()
            newEngine.attach(node)
            newEngine.connect(node, to: newEngine.mainMixerNode, format: pcm.format)
            newEngine.mainMixerNode.outputVolume = self.volume.gain
            newEngine.prepare()
            try newEngine.start()
            engine = newEngine
            player = node
            buffer = pcm
        } catch {
            logger.error("Shutter sound unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setVolume(_ newVolume: ShutterSoundVolume) {
        lock.lock()
        volume = newVolume
        engine?.mainMixerNode.outputVolume = newVolume.gain
        lock.unlock()
    }

    /// Plays the sound now (any thread).
    func play() {
        lock.lock()
        let engine = self.engine
        let player = self.player
        let buffer = self.buffer
        let muted = volume == .off
        lock.unlock()
        guard !muted, let engine, let player, let buffer else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !player.isPlaying {
            player.play()
        }
    }

    /// Stops the engine when the Edition is turned off or the app goes to the background.
    func stop() {
        lock.lock()
        engine?.stop()
        engine = nil
        player = nil
        buffer = nil
        lock.unlock()
    }
}
