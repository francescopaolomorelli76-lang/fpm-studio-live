import Foundation

/// Mastering portato dall'app "Basi per il coro":
/// EQ, normalizzazione in loudness (LUFS, ITU-R BS.1770), compressione e limiter con look-ahead.
enum Mastering {
    enum Mode: String, CaseIterable, Identifiable, Codable {
        case pro, natural
        var id: String { rawValue }
        var label: String { self == .pro ? "Professionale (-14 LUFS)" : "Naturale (-16 LUFS)" }
    }

    struct Biquad {
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        enum Kind { case peak, lowShelf, highShelf, highPass }

        init(_ kind: Kind, f: Double, sr: Double, gainDb: Double = 0, q: Double = 0.7071) {
            let A = pow(10, gainDb / 40), w = 2 * Double.pi * f / sr, cs = cos(w), sn = sin(w), al = sn / (2 * q)
            var nb0, nb1, nb2, a0, na1, na2: Double
            switch kind {
            case .peak:
                nb0 = 1 + al * A; nb1 = -2 * cs; nb2 = 1 - al * A; a0 = 1 + al / A; na1 = -2 * cs; na2 = 1 - al / A
            case .lowShelf:
                let s = 2 * A.squareRoot() * al
                nb0 = A * ((A + 1) - (A - 1) * cs + s); nb1 = 2 * A * ((A - 1) - (A + 1) * cs); nb2 = A * ((A + 1) - (A - 1) * cs - s)
                a0 = (A + 1) + (A - 1) * cs + s; na1 = -2 * ((A - 1) + (A + 1) * cs); na2 = (A + 1) + (A - 1) * cs - s
            case .highShelf:
                let s = 2 * A.squareRoot() * al
                nb0 = A * ((A + 1) + (A - 1) * cs + s); nb1 = -2 * A * ((A - 1) + (A + 1) * cs); nb2 = A * ((A + 1) + (A - 1) * cs - s)
                a0 = (A + 1) - (A - 1) * cs + s; na1 = 2 * ((A - 1) - (A + 1) * cs); na2 = (A + 1) - (A - 1) * cs - s
            case .highPass:
                nb0 = (1 + cs) / 2; nb1 = -(1 + cs); nb2 = (1 + cs) / 2; a0 = 1 + al; na1 = -2 * cs; na2 = 1 - al
            }
            b0 = nb0 / a0; b1 = nb1 / a0; b2 = nb2 / a0; a1 = na1 / a0; a2 = na2 / a0
        }

        mutating func run(_ x: inout [Float], from: Int, to: Int) {
            var x1 = self.x1, x2 = self.x2, y1 = self.y1, y2 = self.y2
            for i in from..<to {
                let v = Double(x[i])
                let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = v; y2 = y1; y1 = y
                x[i] = Float(y)
            }
            self.x1 = x1; self.x2 = x2; self.y1 = y1; self.y2 = y2
        }
    }

    static func eqChain(_ sr: Double) -> [Biquad] {
        [Biquad(.highPass, f: 28, sr: sr), Biquad(.lowShelf, f: 90, sr: sr, gainDb: 4),
         Biquad(.peak, f: 320, sr: sr, gainDb: -1.5, q: 0.9), Biquad(.highShelf, f: 8500, sr: sr, gainDb: 2)]
    }

    /// Loudness integrata in LUFS.
    static func loudness(_ L: [Float], _ R: [Float], sr: Double, from: Int, to: Int) -> Double {
        var kL = [Biquad(.highShelf, f: 1681.97, sr: sr, gainDb: 4), Biquad(.highPass, f: 38.13, sr: sr, q: 0.5)]
        var kR = kL
        let seg = Int(sr * 0.1)
        guard seg > 0, to - from > seg * 4 else { return -70 }
        var buf = [Float](repeating: 0, count: seg)
        var segs: [Double] = []
        var s = from
        while s + seg <= to {
            var e = 0.0
            for ch in 0..<2 {
                let src = ch == 0 ? L : R
                for i in 0..<seg { buf[i] = src[s + i] }
                if ch == 0 { for k in kL.indices { kL[k].run(&buf, from: 0, to: seg) } }
                else { for k in kR.indices { kR[k].run(&buf, from: 0, to: seg) } }
                for i in 0..<seg { e += Double(buf[i] * buf[i]) }
            }
            segs.append(e / Double(seg))
            s += seg
        }
        var blocks: [Double] = []
        if segs.count >= 4 { for i in 0...(segs.count - 4) { blocks.append((segs[i] + segs[i+1] + segs[i+2] + segs[i+3]) / 4) } }
        func lk(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-12)) }
        var g = blocks.filter { lk($0) > -70 }
        guard !g.isEmpty else { return -70 }
        let rel = lk(g.reduce(0, +) / Double(g.count)) - 10
        g = g.filter { lk($0) > rel }
        return lk(g.reduce(0, +) / Double(max(1, g.count)))
    }

    static func gain(_ L: inout [Float], _ R: inout [Float], _ g: Float, from: Int, to: Int) {
        for i in from..<to { L[i] *= g; R[i] *= g }
    }

    static func compress(_ L: inout [Float], _ R: inout [Float], sr: Double, from: Int, to: Int,
                         thresholdDb: Double, ratio: Double, attackMs: Double, releaseMs: Double) {
        let aA = exp(-1 / (sr * attackMs / 1000)), aR = exp(-1 / (sr * releaseMs / 1000)), aD = exp(-1 / (sr * 0.01))
        var ms = 0.0, gr = 0.0
        for i in from..<to {
            let p = Double(max(L[i] * L[i], R[i] * R[i]))
            ms = aD * ms + (1 - aD) * p
            let lv = 10 * log10(ms + 1e-12)
            let over = lv - thresholdDb
            let want = over > 0 ? over * (1 - 1 / ratio) : 0
            gr = want > gr ? aA * gr + (1 - aA) * want : aR * gr + (1 - aR) * want
            let g = Float(pow(10, -gr / 20))
            L[i] *= g; R[i] *= g
        }
    }

    /// Limiter con look-ahead di 5 ms (minimo scorrevole) e rilascio di 80 ms.
    static func limit(_ L: inout [Float], _ R: inout [Float], sr: Double, from: Int, to: Int, ceiling: Float) {
        let la = Int(sr * 0.005), rel = Float(exp(-1 / (sr * 0.08)))
        let n = to - from
        guard n > 0 else { return }
        var req = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let p = max(abs(L[from + i]), abs(R[from + i]))
            req[i] = p > ceiling ? ceiling / p : 1
        }
        var minf = [Float](repeating: 1, count: n)
        var dq = [Int](repeating: 0, count: n)
        var h = 0, t = 0
        var i = n - 1
        while i >= 0 {
            while t > h && req[dq[t - 1]] >= req[i] { t -= 1 }
            dq[t] = i; t += 1
            while dq[h] > i + la { h += 1 }
            minf[i] = req[dq[h]]
            i -= 1
        }
        let att = Float(exp(-1 / (Double(la) / 5)))
        var env: Float = 1
        for k in 0..<n {
            let sm = minf[k]
            env = sm < env ? att * env + (1 - att) * sm : rel * env + (1 - rel) * sm
            L[from + k] = max(-ceiling, min(ceiling, L[from + k] * env))
            R[from + k] = max(-ceiling, min(ceiling, R[from + k] * env))
        }
    }

    static func master(_ L: inout [Float], _ R: inout [Float], sr: Double, mode: Mode, applyEQ: Bool) {
        let n = min(L.count, R.count)
        if applyEQ {
            var eqL = eqChain(sr), eqR = eqChain(sr)
            for k in eqL.indices { eqL[k].run(&L, from: 0, to: n); eqR[k].run(&R, from: 0, to: n) }
        }
        func db(_ x: Double) -> Float { Float(pow(10, x / 20)) }
        if mode == .pro {
            var lu = loudness(L, R, sr: sr, from: 0, to: n)
            gain(&L, &R, db(-16 - lu), from: 0, to: n)
            compress(&L, &R, sr: sr, from: 0, to: n, thresholdDb: -15, ratio: 2.2, attackMs: 20, releaseMs: 250)
            lu = loudness(L, R, sr: sr, from: 0, to: n)
            gain(&L, &R, db(-14 - lu), from: 0, to: n)
        } else {
            let lu = loudness(L, R, sr: sr, from: 0, to: n)
            gain(&L, &R, db(-16 - lu), from: 0, to: n)
        }
        limit(&L, &R, sr: sr, from: 0, to: n, ceiling: 0.89) // ≈ -1 dBTP
    }

    /// Dissolvenze in ingresso/uscita (per esportare parti del brano).
    static func fade(_ L: inout [Float], _ R: inout [Float], inSamples: Int, outSamples: Int) {
        let n = min(L.count, R.count)
        for i in 0..<min(inSamples, n) { let g = Float(i) / Float(max(1, inSamples)); L[i] *= g; R[i] *= g }
        for i in 0..<min(outSamples, n) { let g = Float(i) / Float(max(1, outSamples)); L[n - 1 - i] *= g; R[n - 1 - i] *= g }
    }
}
