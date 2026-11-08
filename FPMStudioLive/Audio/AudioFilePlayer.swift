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

    init() {
        NotificationCenter.default.addObserver(forName: AudioHub.restartedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            let p = self.position
            self.isPlaying = false
            self.seek(to: p)
            self.play()
        }
    }

    func load(_ url: URL) throws {
        stop()
        // Il file viene portato al formato del motore (se serve): i collegamenti restano fissi,
        // così karaoke e Atomix possono suonare insieme senza fermarsi a vicenda.
        let f = try AVAudioFile(forReading: AudioDecode.engineReadyURL(AudioDecode.playableURL(url), format: hub.engineFormat))
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
        try checkAccess(url)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let key = "\(url.path)|\(stamp)".data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let stem = "audio-" + String(key.suffix(80))
        let cached = AppPaths.renderCache.appendingPathComponent(stem + ".caf")
        if FileManager.default.fileExists(atPath: cached.path), (try? AVAudioFile(forReading: cached)) != nil { return cached }

        var reasons: [String] = []
        if let e = Result(catching: { try AVAudioFile(forReading: url) }).failureError { reasons.append("lettura diretta: \(describe(e))") }

        // 2. Copia "ripulita": senza tag ID3 (copertine enormi o tag rovinati bloccano Core Audio)
        //    e con l'estensione giusta secondo il contenuto vero del file.
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
            let (payload, realExt) = sanitize(data, declared: url.pathExtension.lowercased())
            let tmp = AppPaths.renderCache.appendingPathComponent(stem + "-src." + realExt)
            do {
                try payload.write(to: tmp, options: .atomic)
                if (try? AVAudioFile(forReading: tmp)) != nil { return tmp }
                if let u = try? convertWithAsset(tmp, to: cached) { return u }
                reasons.append("copia senza tag (\(realExt)): non leggibile")
            } catch { reasons.append("copia temporanea: \(describe(error))") }
        }
        // 3. Conversione con AVFoundation dal file originale.
        do { return try convertWithAsset(url, to: cached) }
        catch { reasons.append("conversione: \(describe(error))") }
        throw RenderError.engine("formato non riconosciuto da macOS (" + reasons.joined(separator: "; ") + ")")
    }

    /// Porta il file al formato del motore (stereo, stessa frequenza). Se è già giusto, nessuna conversione.
    static func engineReadyURL(_ url: URL, format: AVAudioFormat) throws -> URL {
        let src = try AVAudioFile(forReading: url)
        let inFmt = src.processingFormat
        if inFmt.sampleRate == format.sampleRate && inFmt.channelCount == format.channelCount { return url }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let key = "\(url.path)|\(stamp)|\(Int(format.sampleRate))".data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let dest = AppPaths.renderCache.appendingPathComponent("motore-" + String(key.suffix(80)) + ".caf")
        if FileManager.default.fileExists(atPath: dest.path), (try? AVAudioFile(forReading: dest)) != nil { return dest }
        guard let conv = AVAudioConverter(from: inFmt, to: format) else { throw RenderError.engine("conversione di formato") }
        try? FileManager.default.removeItem(at: dest)
        let out = try AVAudioFile(forWriting: dest, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                                                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false],
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        let cap: AVAudioFrameCount = 32768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: cap) else { return url }
        var eof = false
        while true {
            guard let ob = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32768) else { break }
            var err: NSError?
            let st = conv.convert(to: ob, error: &err) { _, s in
                if eof { s.pointee = .endOfStream; return nil }
                do { try src.read(into: inBuf, frameCount: cap) } catch { eof = true; s.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { eof = true; s.pointee = .endOfStream; return nil }
                s.pointee = .haveData
                return inBuf
            }
            if ob.frameLength > 0 { try out.write(from: ob) }
            if st == .endOfStream || st == .error || ob.frameLength == 0 { break }
        }
        return dest
    }

    /// Permessi e iCloud: messaggi chiari invece di errori generici.
    static func checkAccess(_ url: URL) throws {
        let fm = FileManager.default
        if let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let st = v.ubiquitousItemDownloadingStatus, st != .current {
            try? fm.startDownloadingUbiquitousItem(at: url)
            throw RenderError.engine("il file è su iCloud e non è ancora scaricato sul Mac: lo sto scaricando, riprova tra poco")
        }
        guard fm.fileExists(atPath: url.path) else { throw RenderError.engine("il file non esiste più in questa posizione") }
        guard fm.isReadableFile(atPath: url.path), (try? FileHandle(forReadingFrom: url))?.readData(ofLength: 4).count ?? 0 > 0 else {
            throw RenderError.engine("macOS non permette all'app di leggere questa cartella. Apri Impostazioni di Sistema → Sicurezza e Privacy → Privacy → File e cartelle (o Accesso completo al disco) e abilita FPM Studio Live, poi riprova")
        }
    }

    static func describe(_ e: Error) -> String {
        let n = e as NSError
        if n.domain == NSOSStatusErrorDomain {
            let c = UInt32(bitPattern: Int32(truncatingIfNeeded: n.code))
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((c >> UInt32($0)) & 0xFF))) }
            let fourCC = String(chars).allSatisfy({ $0.isLetter || $0.isNumber || $0 == " " }) ? " '\(String(chars))'" : ""
            return "codice \(n.code)\(fourCC)"
        }
        return n.localizedDescription
    }

    /// Toglie i tag ID3v2/ID3v1 e riconosce il formato reale dai primi byte.
    static func sanitize(_ d: Data, declared: String) -> (Data, String) {
        let b = [UInt8](d.prefix(64))
        func at(_ o: Int, _ s: String) -> Bool { let a = Array(s.utf8); return b.count >= o + a.count && Array(b[o..<(o + a.count)]) == a }
        if at(4, "ftyp") { return (d, "m4a") }
        if at(0, "RIFF") && at(8, "WAVE") { return (d, "wav") }
        if at(0, "FORM") { return (d, "aiff") }
        if at(0, "fLaC") { return (d, "flac") }
        if at(0, "caff") { return (d, "caf") }
        var start = 0
        // Possono esserci più tag ID3 di fila.
        while d.count > start + 10, d[start] == 0x49, d[start + 1] == 0x44, d[start + 2] == 0x33 {
            let size = Int(d[start + 6] & 0x7F) << 21 | Int(d[start + 7] & 0x7F) << 14 | Int(d[start + 8] & 0x7F) << 7 | Int(d[start + 9] & 0x7F)
            let footer = d[start + 5] & 0x10 != 0 ? 10 : 0
            start += 10 + size + footer
        }
        // Cerco la prima sincronia di frame MPEG valida (0xFFE…) o un ADTS AAC (0xFFF…, layer 0).
        var i = min(start, d.count)
        let limit = min(d.count - 4, i + 2_000_000)
        var isADTS = false
        while i < limit {
            if d[i] == 0xFF && d[i + 1] & 0xE0 == 0xE0 {
                let layer = (d[i + 1] >> 1) & 0x03
                let bitrate = d[i + 2] >> 4
                if layer == 0 && d[i + 1] & 0xF0 == 0xF0 { isADTS = true; break }
                if layer != 0 && bitrate != 0 && bitrate != 0x0F && (d[i + 2] >> 2) & 0x03 != 0x03 { break }
            }
            i += 1
        }
        if i >= limit { i = min(start, d.count) }
        var end = d.count
        if end - i > 128, d[end - 128] == 0x54, d[end - 127] == 0x41, d[end - 126] == 0x47 { end -= 128 }   // "TAG" ID3v1
        return (d.subdata(in: i..<max(i, end)), isADTS ? "aac" : (declared.isEmpty ? "mp3" : (declared == "aac" ? "aac" : "mp3")))
    }

    private static func convertWithAsset(_ url: URL, to dest: URL) throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw RenderError.engine("nessuna traccia audio leggibile")
        }
        let reader = try AVAssetReader(asset: asset)
        let sr = 44100.0
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2])
        reader.add(out)
        guard reader.startReading() else { throw RenderError.engine(reader.error.map { describe($0) } ?? "lettura non riuscita") }
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: true)!
        try? FileManager.default.removeItem(at: dest)
        let file = try AVAudioFile(forWriting: dest, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        var frames = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(sb) else { continue }
            let n = CMSampleBufferGetNumSamples(sb)
            guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)), let dst = buf.floatChannelData?[0] else { continue }
            buf.frameLength = AVAudioFrameCount(n)
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n * 8, destination: dst)
            try file.write(from: buf)
            frames += n
        }
        if reader.status == .failed || frames == 0 { throw RenderError.engine(reader.error.map { describe($0) } ?? "nessun audio decodificato") }
        return dest
    }
}

private extension Result where Failure == Error {
    var failureError: Error? { if case .failure(let e) = self { return e }; return nil }
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
