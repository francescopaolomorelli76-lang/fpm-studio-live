import Foundation
import AVFoundation
import JavaScriptCore

struct RenderedAudio {
    var left: [Float]
    var right: [Float]
    var sampleRate: Double
    var duration: Double { Double(left.count) / sampleRate }

    func slice(from: Double, to: Double, fadeIn: Double = 0.01, fadeOut: Double = 0.6) -> RenderedAudio {
        let a = max(0, min(left.count, Int(from * sampleRate)))
        let b = max(a, min(left.count, Int(to * sampleRate)))
        var l = Array(left[a..<b]), r = Array(right[a..<b])
        Mastering.fade(&l, &r, inSamples: Int(fadeIn * sampleRate), outSamples: Int(fadeOut * sampleRate))
        return RenderedAudio(left: l, right: r, sampleRate: sampleRate)
    }

    static func concat(_ parts: [RenderedAudio], gap: Double = 0) -> RenderedAudio {
        guard let sr = parts.first?.sampleRate else { return RenderedAudio(left: [], right: [], sampleRate: 44100) }
        var l: [Float] = [], r: [Float] = []
        let silence = [Float](repeating: 0, count: Int(gap * sr))
        for (i, p) in parts.enumerated() {
            if i > 0 { l += silence; r += silence }
            l += p.left; r += p.right
        }
        return RenderedAudio(left: l, right: r, sampleRate: sr)
    }
}

enum RenderError: LocalizedError {
    case empty, engine(String), encoder(String)
    var errorDescription: String? {
        switch self {
        case .empty: return "La base è vuota: controlla di non aver spento tutti gli strumenti."
        case .engine(let s): return "Errore audio: \(s)"
        case .encoder(let s): return "Errore di codifica: \(s)"
        }
    }
}

/// Rendering più veloce del tempo reale di un MIDI con il SoundFont scelto.
enum OfflineRenderer {
    struct Settings {
        var soundBank: URL?
        var transpose = 0
        var tempo = 1.0
        var muted: Set<Int> = []
        var sampleRate = 44100.0
        var reverb: Float = 14          // % del riverbero di sala aggiunto
        var eq = true
        /// Strumento plugin (es. Roland Sound Canvas VA); nil = SoundFont.
        var pluginID: String? = AppSettings.shared.synthPluginID.isEmpty ? nil : AppSettings.shared.synthPluginID
    }

    static func render(_ midi: MIDIFile, settings: Settings, progress: @escaping (Double) -> Void) throws -> RenderedAudio {
        let sr = settings.sampleRate
        let engine = AVAudioEngine()
        let synth = settings.pluginID.flatMap { GMSynth.makePlugin(id: $0, name: "") } ?? GMSynth()
        let eq = AVAudioUnitEQ(numberOfBands: 4)
        let reverb = AVAudioUnitReverb()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let nodes: [AVAudioNode] = [synth.node, eq, reverb]
        nodes.forEach { engine.attach($0) }
        AudioHub.configureSynthEQ(eq, enabled: settings.eq)
        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = settings.reverb
        engine.connect(synth.node, to: eq, format: fmt)
        engine.connect(eq, to: reverb, format: fmt)
        engine.connect(reverb, to: engine.mainMixerNode, format: fmt)
        let maxFrames: AVAudioFrameCount = 1024
        do {
            try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)
            synth.loadSoundBank(settings.soundBank)
            try engine.start()
        } catch { throw RenderError.engine(error.localizedDescription) }
        defer { engine.stop() }

        let seq = MIDISequencer(synth: synth)
        seq.sampleRate = sr
        seq.load(midi)
        seq.speed = settings.tempo
        seq.setTranspose(settings.transpose)
        for ch in settings.muted { seq.setMuted(ch, true) }
        seq.tail = 0
        seq.play()

        let total = Int(sr * (midi.duration / settings.tempo + 3.0))
        var L = [Float](repeating: 0, count: total), R = [Float](repeating: 0, count: total)
        guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else { throw RenderError.engine("buffer") }
        var done = 0
        var lastReport = Date()
        while done < total {
            let n = AVAudioFrameCount(min(Int(maxFrames), total - done))
            let st: AVAudioEngineManualRenderingStatus
            do { st = try engine.renderOffline(n, to: buf) } catch { throw RenderError.engine(error.localizedDescription) }
            guard st == .success, let ch = buf.floatChannelData else { break }
            let got = Int(buf.frameLength)
            let stereo = buf.format.channelCount > 1
            for i in 0..<got { L[done + i] = ch[0][i]; R[done + i] = stereo ? ch[1][i] : ch[0][i] }
            done += got
            if Date().timeIntervalSince(lastReport) > 0.1 { progress(Double(done) / Double(total)); lastReport = Date() }
        }
        // Taglio del silenzio finale (lascio 0,3 s di coda).
        var end = done
        while end > Int(sr) && abs(L[end - 1]) + abs(R[end - 1]) < 0.00005 { end -= 1 }
        end = min(done, end + Int(sr * 0.3))
        if end < Int(sr * 0.5) { throw RenderError.empty }
        L.removeSubrange(end..<L.count); R.removeSubrange(end..<R.count)
        progress(1)
        return RenderedAudio(left: L, right: R, sampleRate: sr)
    }
}

enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case mp3, wav, m4a, mid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .mp3: return "MP3 320 kbps"
        case .wav: return "WAV 24 bit"
        case .m4a: return "M4A (AAC 256 kbps)"
        case .mid: return "MIDI (.mid)"
        }
    }
}

enum AudioExporter {
    static func write(_ audio: RenderedAudio, to url: URL, format: ExportFormat, progress: @escaping (Double) -> Void = { _ in }) throws {
        switch format {
        case .mp3:
            let data = try MP3Encoder.encode(audio, kbps: 320, progress: progress)
            try data.write(to: url, options: .atomic)
        case .wav, .m4a:
            try? FileManager.default.removeItem(at: url)
            let settings: [String: Any] = format == .wav
                ? [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audio.sampleRate, AVNumberOfChannelsKey: 2,
                   AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
                : [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audio.sampleRate, AVNumberOfChannelsKey: 2,
                   AVEncoderBitRateKey: 256_000]
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch { throw RenderError.encoder(error.localizedDescription) }
            let chunk = 32768
            let fmt = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 2)!
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk)) else { return }
            var s = 0
            while s < audio.left.count {
                let n = min(chunk, audio.left.count - s)
                for i in 0..<n { buf.floatChannelData![0][i] = audio.left[s + i]; buf.floatChannelData![1][i] = audio.right[s + i] }
                buf.frameLength = AVAudioFrameCount(n)
                do { try file.write(from: buf) } catch { throw RenderError.encoder(error.localizedDescription) }
                s += n
                progress(Double(s) / Double(audio.left.count))
            }
        case .mid:
            break
        }
    }
}

/// Codifica MP3 con LAME (lamejs, LGPL) eseguito da JavaScriptCore, incluso in macOS:
/// nessuna libreria da installare, MP3 vero a 320 kbps.
enum MP3Encoder {
    static func encode(_ audio: RenderedAudio, kbps: Int, progress: @escaping (Double) -> Void) throws -> Data {
        guard let url = Bundle.main.url(forResource: "lame.min", withExtension: "js"),
              let src = try? String(contentsOf: url), let ctx = JSContext() else {
            throw RenderError.encoder("encoder MP3 mancante (lame.min.js)")
        }
        var jsError: String?
        ctx.exceptionHandler = { _, ex in jsError = ex?.toString() }
        ctx.evaluateScript(src)
        let sr = Int(audio.sampleRate)
        let chunk = 1152 * 64
        ctx.evaluateScript("""
        var __enc = new lamejs.Mp3Encoder(2, \(sr), \(kbps));
        var __parts = []; var __size = 0;
        var __L = new Int16Array(\(chunk)); var __R = new Int16Array(\(chunk));
        function __encode(n) {
          for (var s = 0; s < n; s += 1152) {
            var m = Math.min(1152, n - s);
            var d = __enc.encodeBuffer(__L.subarray(s, s + m), __R.subarray(s, s + m));
            if (d.length) { __parts.push(new Uint8Array(d.buffer, d.byteOffset, d.length).slice()); __size += d.length; }
          }
        }
        function __finish() {
          var t = __enc.flush(); if (t.length) { __parts.push(new Uint8Array(t.buffer, t.byteOffset, t.length).slice()); __size += t.length; }
          var all = new Uint8Array(__size); var o = 0;
          for (var i = 0; i < __parts.length; i++) { all.set(__parts[i], o); o += __parts[i].length; }
          __parts = []; return all;
        }
        """)
        if let e = jsError { throw RenderError.encoder(e) }
        guard let lv = ctx.objectForKeyedSubscript("__L"), let rv = ctx.objectForKeyedSubscript("__R"),
              let encodeFn = ctx.objectForKeyedSubscript("__encode") else { throw RenderError.encoder("init") }
        let gctx = ctx.jsGlobalContextRef
        guard let lp = JSObjectGetTypedArrayBytesPtr(gctx, lv.jsValueRef, nil)?.assumingMemoryBound(to: Int16.self),
              let rp = JSObjectGetTypedArrayBytesPtr(gctx, rv.jsValueRef, nil)?.assumingMemoryBound(to: Int16.self) else {
            throw RenderError.encoder("memoria")
        }
        let total = audio.left.count
        var s = 0
        while s < total {
            let n = min(chunk, total - s)
            for i in 0..<n {
                lp[i] = Int16(max(-1, min(1, audio.left[s + i])) * 32767)
                rp[i] = Int16(max(-1, min(1, audio.right[s + i])) * 32767)
            }
            encodeFn.call(withArguments: [n])
            if let e = jsError { throw RenderError.encoder(e) }
            s += n
            progress(Double(s) / Double(total))
        }
        guard let all = ctx.objectForKeyedSubscript("__finish")?.call(withArguments: []),
              let ptr = JSObjectGetTypedArrayBytesPtr(gctx, all.jsValueRef, nil) else { throw RenderError.encoder("output") }
        let len = JSObjectGetTypedArrayByteLength(gctx, all.jsValueRef, nil)
        return Data(bytes: ptr, count: len)
    }
}
