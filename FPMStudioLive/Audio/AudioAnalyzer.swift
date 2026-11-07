import Foundation
import AVFoundation
import Accelerate

/// Analisi di un file audio: BPM, battiti, battere, accordi per battito (Viterbi) e tonalità.
/// Porta in Swift "Accordi da un MP3" dell'app originale, con FFT accelerata (vDSP).
enum AudioAnalyzer {
    struct Result: Codable {
        var bpm: Double
        var beats: [Double]          // secondi
        var downbeatOffset: Int
        var chords: [ChordEvent]
        var keyRoot: Int
        var keyMinor: Bool
        var leadIn: Double           // primo suono
        var lastSound: Double        // ultimo suono
        var duration: Double
        var waveform: [Float]        // 800 picchi per la forma d'onda

        var bars: [Double] {
            guard beats.count > 4 else { return [] }
            var out: [Double] = []
            var i = downbeatOffset
            while i < beats.count { out.append(beats[i]); i += 4 }
            if let f = out.first, f > 0.5 { out.insert(0, at: 0) }
            return out
        }
    }

    static let sr = 22050.0

    /// Decodifica in mono a 22,05 kHz.
    static func decodeMono(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        let outFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw RenderError.engine("convertitore") }
        let inCap: AVAudioFrameCount = 65536
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCap) else { return [] }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(file.length) * sr / inFmt.sampleRate) + 1024)
        var eof = false
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 65536) else { break }
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, st in
                if eof { st.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: inBuf, frameCount: inCap)
                } catch { eof = true; st.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { eof = true; st.pointee = .endOfStream; return nil }
                st.pointee = .haveData
                return inBuf
            }
            if let d = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: d, count: Int(outBuf.frameLength)))
            }
            if status == .endOfStream || status == .error || outBuf.frameLength == 0 { break }
        }
        return out
    }

    static func analyze(url: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> Result {
        let x = try decodeMono(url)
        return analyze(samples: x, progress: progress)
    }

    static func analyze(samples x: [Float], progress: @escaping (Double) -> Void) -> Result {
        let N = 2048, H = 256, bins = N / 2
        let duration = Double(x.count) / sr
        let nF = max(0, (x.count - N) / H)
        var pcOf = [Int](repeating: -1, count: bins), bassOf = [Int](repeating: -1, count: bins)
        for k in 1..<bins {
            let f = Double(k) * sr / Double(N)
            let m = Int((69 + 12 * log2(f / 440)).rounded())
            if f >= 70 && f <= 2100 { pcOf[k] = ((m % 12) + 12) % 12 }
            if f >= 40 && f <= 260 { bassOf[k] = ((m % 12) + 12) % 12 }
        }
        var chroma = [Float](repeating: 0, count: nF * 12), bassC = [Float](repeating: 0, count: nF * 12)
        var onset = [Float](repeating: 0, count: nF), energy = [Float](repeating: 0, count: nF)

        let log2n = vDSP_Length(log2(Double(N)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return Result(bpm: 120, beats: [], downbeatOffset: 0, chords: [], keyRoot: 0, keyMinor: false, leadIn: 0, lastSound: duration, duration: duration, waveform: [])
        }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: N)
        vDSP_hann_window(&window, vDSP_Length(N), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: N)
        var re = [Float](repeating: 0, count: bins), im = [Float](repeating: 0, count: bins)
        var mag = [Float](repeating: 0, count: bins), prev = [Float](repeating: 0, count: bins)
        for f in 0..<nF {
            x.withUnsafeBufferPointer { xp in
                vDSP_vmul(xp.baseAddress! + f * H, 1, window, 1, &frame, 1, vDSP_Length(N))
            }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(bins))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &mag, 1, vDSP_Length(bins))
                }
            }
            var fl: Float = 0, en: Float = 0
            for k in 1..<bins {
                let m = mag[k] * 0.5   // vDSP_fft_zrip restituisce 2× la DFT
                let lm = log(1 + 100 * m)
                if k < bins / 2 { let d = lm - prev[k]; if d > 0 { fl += d } }
                prev[k] = lm
                en += m * m
                if pcOf[k] >= 0 { chroma[f * 12 + pcOf[k]] += lm }
                if bassOf[k] >= 0 { bassC[f * 12 + bassOf[k]] += lm }
            }
            onset[f] = fl; energy[f] = en
            if f % 2000 == 0 { progress(0.6 * Double(f) / Double(max(1, nF))) }
        }

        // Tempo: autocorrelazione dell'onset con preferenza intorno a 110 BPM.
        let fps = sr / Double(H)
        var o = [Float](repeating: 0, count: nF)
        do {
            let w = Int(fps.rounded())
            var acc = [Float](repeating: 0, count: nF + 1)
            for i in 0..<nF { acc[i + 1] = acc[i] + onset[i] }
            for i in 0..<nF {
                let a = max(0, i - w), b = min(nF, i + w)
                let mean = (acc[b] - acc[a]) / Float(max(1, b - a))
                o[i] = max(0, onset[i] - mean)
            }
        }
        var bestLag = 0, bestV: Float = -1
        let minL = Int(fps * 60 / 190), maxL = Int((fps * 60 / 55).rounded(.up))
        if nF > maxL {
            for L in minL...maxL {
                var s: Float = 0
                o.withUnsafeBufferPointer { op in
                    vDSP_dotpr(op.baseAddress! + L, 1, op.baseAddress!, 1, &s, vDSP_Length(nF - L))
                }
                let bpm = 60 * fps / Double(L)
                let wgt = Float(exp(-0.5 * pow(log2(bpm / 110) / 0.9, 2)))
                s *= wgt
                if s > bestV { bestV = s; bestLag = L }
            }
        }
        let P = bestLag > 0 ? bestLag : Int(fps / 2)
        // Battiti con programmazione dinamica.
        var C = [Float](repeating: 0, count: nF), back = [Int](repeating: -1, count: nF)
        for t in 0..<nF {
            var bv: Float = 0, bi = -1
            let lo = t - 2 * P, hi = t - P / 2
            if hi >= 0 {
                for tau in max(0, lo)...hi {
                    let r = log(Double(t - tau) / Double(P))
                    let v = C[tau] - Float(80 * r * r)
                    if bi < 0 || v > bv { bv = v; bi = tau }
                }
            }
            C[t] = o[t] + (bi >= 0 ? max(0, bv) : 0)
            back[t] = bi
            if t % 4000 == 0 { progress(0.6 + 0.2 * Double(t) / Double(max(1, nF))) }
        }
        var beatsF: [Int] = []
        if nF > 0 {
            var t = max(0, nF - P)
            for i in max(0, nF - P)..<nF where C[i] > C[t] { t = i }
            var cur = t
            while cur >= 0 { beatsF.insert(cur, at: 0); cur = back[cur] }
        }

        // Accordi per battito: maggiori, minori, settima (Viterbi con permanenza).
        let maxE = energy.max() ?? 1
        struct BeatChroma { var w: [Float]; var bw: [Float]; var quiet: Bool }
        var beatCh: [BeatChroma] = []
        for (bIdx, a) in beatsF.enumerated() {
            let e = bIdx + 1 < beatsF.count ? beatsF[bIdx + 1] : min(nF, a + P)
            var w = [Float](repeating: 0, count: 12), bw = [Float](repeating: 0, count: 12)
            var en: Float = 0
            if e > a {
                for f in a..<e { for i in 0..<12 { w[i] += chroma[f * 12 + i]; bw[i] += bassC[f * 12 + i] }; en += energy[f] }
            }
            beatCh.append(BeatChroma(w: w, bw: bw, quiet: en / Float(max(1, e - a)) < maxE * 0.002))
        }
        let templ: [Chord] = (0..<12).flatMap { r in [Chord(root: r, quality: .major), Chord(root: r, quality: .minor), Chord(root: r, quality: .seventh)] }
        let bassW: Float = 0.3, sevP: Float = 0.1
        let tvec: [[Float]] = templ.map { T -> [Float] in
            var v = [Float](repeating: 0, count: 12)
            for (i, iv) in T.quality.intervals.enumerated() { v[(T.root + iv) % 12] = i == 0 ? 1.2 : 1 }
            return v
        }
        let emis: [[Float]] = beatCh.map { bc -> [Float] in
            if bc.quiet { return [Float](repeating: 0, count: templ.count) }
            let mn = bc.w.min() ?? 0
            let w = bc.w.map { max(0, $0 - mn) }
            let nrm = max(1e-6, sqrt(w.reduce(0) { $0 + $1 * $1 }))
            let bmn = bc.bw.min() ?? 0, bmx = max(1e-6, (bc.bw.max() ?? 0) - bmn)
            let bn = bc.bw.map { ($0 - bmn) / bmx }
            return templ.enumerated().map { ti, T -> Float in
                let v = tvec[ti]
                let vn = sqrt(v.reduce(0) { $0 + $1 * $1 })
                var s: Float = 0
                for i in 0..<12 { s += w[i] * v[i] }
                s /= nrm * vn
                let pcs = Set(T.pitchClasses)
                let outBass = (0..<12).filter { !pcs.contains($0) }.map { bn[$0] }.max() ?? 0
                s += bassW * bn[T.root] - 0.5 * bassW * outBass
                if T.quality == .seventh { s -= sevP }
                return s
            }
        }
        var path = [Int](repeating: 0, count: emis.count)
        if !emis.isEmpty {
            let S = templ.count, stay: Float = 0.12
            var score = emis[0]
            var bp: [[Int]] = []
            for b in 1..<max(1, emis.count) where b < emis.count {
                let m = score.max() ?? 0
                let am = score.firstIndex(of: m) ?? 0
                var ns = [Float](repeating: 0, count: S), bk = [Int](repeating: 0, count: S)
                for s in 0..<S {
                    let st = score[s] + stay
                    if st >= m { ns[s] = st + emis[b][s]; bk[s] = s } else { ns[s] = m + emis[b][s]; bk[s] = am }
                }
                score = ns; bp.append(bk)
            }
            path[emis.count - 1] = score.firstIndex(of: score.max() ?? 0) ?? 0
            if emis.count >= 2 { for b in stride(from: emis.count - 2, through: 0, by: -1) { path[b] = bp[b][path[b + 1]] } }
        }
        var keyW = [Double](repeating: 0, count: 12)
        for (i, s) in path.enumerated() where i < beatCh.count && !beatCh[i].quiet {
            for (j, iv) in templ[s].quality.intervals.enumerated() { keyW[(templ[s].root + iv) % 12] += j == 0 ? 1.5 : 1 }
        }
        let key = KeyDetector.detect(keyW)
        // Battere: sfasamento in cui i cambi d'accordo cadono più spesso a inizio battuta.
        var down = 0, bestD = -1
        for d in 0..<4 {
            var c = 0
            for b in 1..<max(1, path.count) where b < path.count && path[b] != path[b - 1] && (b - d) % 4 == 0 { c += 1 }
            if c > bestD { bestD = c; down = d }
        }
        let beats = beatsF.map { Double($0 * H) / sr }
        var chords: [ChordEvent] = []
        for (i, s) in path.enumerated() where i < beats.count {
            let c: Chord? = beatCh[i].quiet ? nil : templ[s]
            if chords.last?.chord != c || chords.isEmpty { chords.append(ChordEvent(time: beats[i], chord: c)) }
        }
        // Inizio e fine del suono, forma d'onda.
        let thr = (x.map { abs($0) }.max() ?? 1) * 0.02
        let first = x.firstIndex { abs($0) > thr } ?? 0
        let last = x.lastIndex { abs($0) > thr } ?? x.count
        let points = 800
        var wave = [Float](repeating: 0, count: points)
        if !x.isEmpty {
            let step = max(1, x.count / points)
            for p in 0..<points {
                let a = p * step, b = min(x.count, a + step)
                if a < b { var mx: Float = 0; for i in a..<b { mx = max(mx, abs(x[i])) }; wave[p] = mx }
            }
        }
        progress(1)
        return Result(bpm: 60 * fps / Double(P), beats: beats, downbeatOffset: down, chords: chords,
                      keyRoot: key.root, keyMinor: key.minor, leadIn: Double(first) / sr, lastSound: Double(last) / sr,
                      duration: duration, waveform: wave)
    }

    /// Solo forma d'onda, inizio/fine e BPM (più veloce, per i deck DJ).
    static func quickAnalyze(url: URL) throws -> Result {
        try analyze(url: url)
    }
}
