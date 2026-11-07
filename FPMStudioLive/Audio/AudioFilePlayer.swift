import Foundation
import AVFoundation

/// Riproduce mp3/m4a/wav e l'audio dei video con tono e tempo indipendenti.
final class AudioFilePlayer {
    private let hub = AudioHub.shared
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var scheduledToken = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    var onEnd: (() -> Void)?

    var player: AVAudioPlayerNode { hub.filePlayer }

    func load(_ url: URL) throws {
        stop()
        let f = try AVAudioFile(forReading: url)
        file = f
        duration = Double(f.length) / f.processingFormat.sampleRate
        startFrame = 0
    }

    var isLoaded: Bool { file != nil }

    var position: Double {
        guard let f = file else { return 0 }
        let sr = f.processingFormat.sampleRate
        if isPlaying, let nt = player.lastRenderTime, let pt = player.playerTime(forNodeTime: nt) {
            return min(duration, Double(startFrame) / sr + Double(pt.sampleTime) / pt.sampleRate)
        }
        return Double(startFrame) / sr
    }

    func play() {
        guard let f = file, !isPlaying else { return }
        hub.start()
        schedule(from: startFrame, file: f)
        player.play()
        isPlaying = true
    }

    func pause() {
        guard isPlaying else { return }
        let p = position
        isPlaying = false
        scheduledToken += 1
        player.stop()
        if let f = file { startFrame = AVAudioFramePosition(p * f.processingFormat.sampleRate) }
    }

    func stop() {
        isPlaying = false
        scheduledToken += 1
        player.stop()
        startFrame = 0
    }

    func seek(to seconds: Double) {
        guard let f = file else { return }
        let was = isPlaying
        if was { isPlaying = false; scheduledToken += 1; player.stop() }
        startFrame = AVAudioFramePosition(max(0, min(seconds, duration)) * f.processingFormat.sampleRate)
        if was { play() }
    }

    private func schedule(from frame: AVAudioFramePosition, file f: AVAudioFile) {
        let remaining = AVAudioFrameCount(max(0, f.length - frame))
        guard remaining > 0 else { return }
        scheduledToken += 1
        let token = scheduledToken
        player.scheduleSegment(f, startingFrame: frame, frameCount: remaining, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.scheduledToken == token, self.isPlaying else { return }
                self.isPlaying = false
                self.startFrame = 0
                self.onEnd?()
            }
        }
    }

    /// Tono in semitoni e tempo (1 = originale).
    func set(transpose: Int, tempo: Double) {
        hub.fileTimePitch.pitch = Float(transpose * 100)
        hub.fileTimePitch.rate = Float(tempo)
    }
}
