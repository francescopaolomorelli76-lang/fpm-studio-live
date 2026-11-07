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
        let f = try AVAudioFile(forReading: AudioDecode.playableURL(url))
        // Ricollego la catena con il formato del file (mono/stereo, 44,1/48 kHz): evita errori di formato.
        let e = hub.engine
        e.disconnectNodeOutput(player)
        e.disconnectNodeOutput(hub.fileTimePitch)
        e.connect(player, to: hub.fileTimePitch, format: f.processingFormat)
        e.connect(hub.fileTimePitch, to: hub.karaokeMixer, fromBus: 0, toBus: 1, format: f.processingFormat)
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

/// Apertura sicura dei file audio: se Core Audio non riesce a leggerli direttamente
/// (MP3 con tag strani, AAC in contenitori video, WMA non supportato…) li converte una volta
/// in un file PCM nella cache tramite AVAssetReader.
enum AudioDecode {
    static func playableURL(_ url: URL) throws -> URL {
        if (try? AVAudioFile(forReading: url)) != nil { return url }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let key = "\(url.path)|\(stamp)".data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let dest = AppPaths.renderCache.appendingPathComponent("audio-" + String(key.suffix(80)) + ".caf")
        if FileManager.default.fileExists(atPath: dest.path), (try? AVAudioFile(forReading: dest)) != nil { return dest }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw RenderError.engine("il file \(url.lastPathComponent) non contiene audio leggibile")
        }
        let reader = try AVAssetReader(asset: asset)
        let sr = 44100.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2])
        reader.add(out)
        guard reader.startReading() else { throw RenderError.engine(reader.error?.localizedDescription ?? "lettura non riuscita") }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: true)!
        try? FileManager.default.removeItem(at: dest)
        let file = try AVAudioFile(forWriting: dest, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)), let dst = buf.floatChannelData?[0] else { continue }
            buf.frameLength = AVAudioFrameCount(n)
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 8, destination: dst)
            try file.write(from: buf)
        }
        if reader.status == .failed { throw RenderError.engine(reader.error?.localizedDescription ?? "conversione non riuscita") }
        return dest
    }
}

/// Trova audio e grafica CDG: MP3+G (stesso nome), file .cdg scelto direttamente, oppure ZIP che li contiene.
enum MediaResolver {
    struct Media { var audio: URL; var cdg: URL? }
    static let audioExts = ["mp3", "m4a", "wav", "aif", "aiff", "flac", "ogg", "aac", "caf"]

    static func resolve(_ url: URL) throws -> Media {
        let ext = url.pathExtension.lowercased()
        if ext == "zip" { return try fromZip(url) }
        if ext == "cdg" {
            guard let a = sibling(of: url, exts: audioExts) else { throw RenderError.engine("manca l'MP3 con lo stesso nome del file CDG") }
            return Media(audio: a, cdg: url)
        }
        return Media(audio: url, cdg: sibling(of: url, exts: ["cdg"]))
    }

    static func sibling(of url: URL, exts: [String]) -> URL? {
        let base = url.deletingPathExtension()
        for e in exts {
            for v in [e, e.uppercased()] {
                let u = base.appendingPathExtension(v)
                if FileManager.default.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    private static func fromZip(_ url: URL) throws -> Media {
        let key = url.path.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let dir = AppPaths.renderCache.appendingPathComponent("zip-" + String(key.suffix(60)), isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            p.arguments = ["-x", "-k", url.path, dir.path]
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { try? FileManager.default.removeItem(at: dir); throw RenderError.engine("ZIP non leggibile") }
        }
        let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { !$0.path.contains("__MACOSX") }
        guard let audio = files.first(where: { audioExts.contains($0.pathExtension.lowercased()) }) else {
            throw RenderError.engine("lo ZIP non contiene un MP3")
        }
        let cdg = files.first { $0.pathExtension.lowercased() == "cdg" }
        return Media(audio: audio, cdg: cdg)
    }
}
