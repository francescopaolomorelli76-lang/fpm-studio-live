import Foundation
import AVFoundation

/// Formati di esportazione dell'Audio Lab.
enum AudioLabFormat: String, CaseIterable, Identifiable, Codable {
    case mp3_320, mp3_192, wav24, wav16, aiff, m4a, alac, flac, caf
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mp3_320: return "MP3 320 kbps"
        case .mp3_192: return "MP3 192 kbps"
        case .wav24: return "WAV 24 bit"
        case .wav16: return "WAV 16 bit (CD)"
        case .aiff: return "AIFF 16 bit"
        case .m4a: return "M4A (AAC 256 kbps)"
        case .alac: return "Apple Lossless (ALAC)"
        case .flac: return "FLAC"
        case .caf: return "CAF 24 bit"
        }
    }
    /// Suffisso del file (con estensione).
    var suffix: String {
        switch self {
        case .mp3_320: return ".mp3"
        case .mp3_192: return " (192).mp3"
        case .wav24: return ".wav"
        case .wav16: return " (16 bit).wav"
        case .aiff: return ".aiff"
        case .m4a: return ".m4a"
        case .alac: return " (lossless).m4a"
        case .flac: return ".flac"
        case .caf: return ".caf"
        }
    }
}

enum AudioLabDSP {
    static let sampleRate = 44100.0

    // MARK: Lettura

    /// Apre qualsiasi file audio o video leggibile da macOS e lo porta a 44,1 kHz stereo.
    static func decode(_ url: URL) throws -> RenderedAudio {
        let playable = try AudioDecode.playableURL(url)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let ready = try AudioDecode.engineReadyURL(playable, format: fmt)
        let f = try AVAudioFile(forReading: ready)
        let total = Int(f.length)
        guard total > 0 else { throw RenderError.empty }
        var L = [Float](), R = [Float]()
        L.reserveCapacity(total); R.reserveCapacity(total)
        let cap: AVAudioFrameCount = 65536
        guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: cap) else { throw RenderError.engine("memoria") }
        let mono = f.processingFormat.channelCount == 1
        while f.framePosition < f.length {
            try f.read(into: buf, frameCount: cap)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            let l = buf.floatChannelData![0]
            let r = mono ? l : buf.floatChannelData![1]
            L.append(contentsOf: UnsafeBufferPointer(start: l, count: n))
            R.append(contentsOf: UnsafeBufferPointer(start: r, count: n))
        }
        return RenderedAudio(left: L, right: R, sampleRate: f.processingFormat.sampleRate)
    }

    // MARK: Trasposizione e tempo

    /// Cambia tonalità (semitoni) e velocità senza cambiare l'altra, con il TimePitch di Apple, offline.
    static func pitchAndTempo(_ a: RenderedAudio, semitones: Double, tempo: Double, progress: (Double) -> Void = { _ in }) throws -> RenderedAudio {
        if abs(semitones) < 0.01 && abs(tempo - 1) < 0.001 { return a }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: a.sampleRate, channels: 2)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let tp = AVAudioUnitTimePitch()
        tp.pitch = Float(semitones * 100)
        tp.rate = Float(tempo)
        tp.overlap = 16
        engine.attach(player); engine.attach(tp)
        engine.connect(player, to: tp, format: fmt)
        engine.connect(tp, to: engine.mainMixerNode, format: fmt)
        let block: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
        try engine.start()

        // Il brano viene passato a pezzi, per non raddoppiare la memoria.
        let chunk = 262_144
        var s = 0
        while s < a.left.count {
            let n = min(chunk, a.left.count - s)
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { break }
            a.left.withUnsafeBufferPointer { b.floatChannelData![0].assign(from: $0.baseAddress! + s, count: n) }
            a.right.withUnsafeBufferPointer { b.floatChannelData![1].assign(from: $0.baseAddress! + s, count: n) }
            b.frameLength = AVAudioFrameCount(n)
            player.scheduleBuffer(b, completionHandler: nil)
            s += n
        }
        player.play()

        let outTotal = Int(Double(a.left.count) / tempo) + Int(a.sampleRate * 0.3)
        var L = [Float](), R = [Float]()
        L.reserveCapacity(outTotal); R.reserveCapacity(outTotal)
        guard let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block) else { throw RenderError.engine("memoria") }
        while L.count < outTotal {
            let want = AVAudioFrameCount(min(Int(block), outTotal - L.count))
            let st = try engine.renderOffline(want, to: out)
            guard st == .success else { break }
            let n = Int(out.frameLength)
            L.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: n))
            R.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![1], count: n))
            if L.count % (Int(block) * 64) == 0 { progress(Double(L.count) / Double(outTotal)) }
        }
        engine.stop()
        return RenderedAudio(left: L, right: R, sampleRate: a.sampleRate)
    }

    // MARK: Separazione rapida (senza internet)

    /// Base senza voce "rapida": toglie ciò che sta al centro dello stereo (di solito la voce)
    /// e rimette i bassi originali, che altrimenti sparirebbero con la voce. Non perfetta, ma immediata.
    static func quickInstrumental(_ a: RenderedAudio) -> RenderedAudio {
        let n = min(a.left.count, a.right.count)
        var mid = [Float](repeating: 0, count: n)
        var side = [Float](repeating: 0, count: n)
        for i in 0..<n {
            mid[i] = (a.left[i] + a.right[i]) * 0.5
            side[i] = (a.left[i] - a.right[i]) * 0.5
        }
        // Bassi (sotto ~160 Hz) presi dal centro: cassa e basso restano.
        var high = mid
        var hp = Mastering.Biquad(.highPass, f: 160, sr: a.sampleRate)
        var hp2 = Mastering.Biquad(.highPass, f: 160, sr: a.sampleRate)
        hp.run(&high, from: 0, to: n)
        hp2.run(&high, from: 0, to: n)
        var L = [Float](repeating: 0, count: n), R = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let low = mid[i] - high[i]
            L[i] = side[i] * 1.6 + low
            R[i] = -side[i] * 1.6 + low
        }
        return RenderedAudio(left: L, right: R, sampleRate: a.sampleRate)
    }

    /// Somma di più tracce (per esempio batteria + basso + altro = base).
    static func mix(_ parts: [RenderedAudio]) -> RenderedAudio? {
        guard let first = parts.first else { return nil }
        let n = parts.map { $0.left.count }.max() ?? 0
        var L = [Float](repeating: 0, count: n), R = [Float](repeating: 0, count: n)
        for p in parts {
            for i in 0..<p.left.count { L[i] += p.left[i]; R[i] += p.right[i] }
        }
        return RenderedAudio(left: L, right: R, sampleRate: first.sampleRate)
    }

    // MARK: Scrittura

    static func write(_ a: RenderedAudio, to url: URL, format: AudioLabFormat, progress: @escaping (Double) -> Void = { _ in }) throws {
        try? FileManager.default.removeItem(at: url)
        switch format {
        case .mp3_320, .mp3_192:
            let data = try MP3Encoder.encode(a, kbps: format == .mp3_320 ? 320 : 192, progress: progress)
            try data.write(to: url, options: .atomic)
            return
        default: break
        }
        let sr = a.sampleRate
        let settings: [String: Any]
        switch format {
        case .wav24, .caf:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .wav16:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .aiff:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]
        case .m4a:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256_000]
        case .alac:
            settings = [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
        case .flac:
            settings = [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16]
        default:
            settings = [:]
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch { throw RenderError.encoder("\(format.label): \(error.localizedDescription)") }
        let chunk = 32768
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)) else { return }
        var s = 0
        while s < a.left.count {
            let n = min(chunk, a.left.count - s)
            for i in 0..<n {
                buf.floatChannelData![0][i] = max(-1, min(1, a.left[s + i]))
                buf.floatChannelData![1][i] = max(-1, min(1, a.right[s + i]))
            }
            buf.frameLength = AVAudioFrameCount(n)
            do { try file.write(from: buf) } catch { throw RenderError.encoder("\(format.label): \(error.localizedDescription)") }
            s += n
            progress(Double(s) / Double(a.left.count))
        }
    }
}
