import Foundation

/// Regione armonica in tick.
struct ChordRegion: Hashable {
    var startTick: Int
    var endTick: Int
    var chord: Chord?
}

/// Riconoscimento accordi dal MIDI.
/// Porta in Swift l'algoritmo dell'app "Basi per il coro" (tappeti armonici pesati per area,
/// fondamentale rinforzata dal basso, isteresi e livellamento), con due miglioramenti:
/// - se non ci sono organi/archi/pad usa le altre tracce polifoniche (mai la melodia);
/// - riconosce anche i rivolti (basso diverso dalla fondamentale).
enum ChordEngine {

    struct Analysis {
        var regions: [ChordRegion]
        var key: (root: Int, minor: Bool)
        var melodyChannel: Int?
        var bassChannels: Set<Int>
        var harmonyChannels: Set<Int>
        var usedFallback: Bool
    }

    static let templates: [Chord.Quality] = [.major, .minor, .seventh, .major7, .minor7, .sus4, .sus2, .dim, .halfDim, .aug]

    static func isBassProgram(_ p: Int) -> Bool { (32...39).contains(p) }
    static func isPadLike(_ p: Int) -> Bool { (48...55).contains(p) || (88...95).contains(p) }
    static func isStrictHarmony(_ p: Int) -> Bool { (16...20).contains(p) || (48...51).contains(p) || (88...95).contains(p) }

    static func analyze(_ midi: MIDIFile, lyrics: KaraokeLyrics?, melodyOverride: Int? = nil) -> Analysis {
        let notes = midi.notes.filter { $0.endTick > $0.startTick }
        let byCh = Dictionary(grouping: notes, by: { $0.channel })
        let melody = melodyOverride ?? MelodyDetector.detect(midi, lyrics: lyrics)

        // Bassi: programma GM basso, oppure traccia monofonica molto grave.
        var bass = Set<Int>()
        for (ch, ns) in byCh where ch != 9 {
            let prog = midi.programs[ch] ?? 0
            let avg = Double(ns.map { $0.pitch }.reduce(0, +)) / Double(max(1, ns.count))
            if isBassProgram(prog) || (avg < 47 && polyphony(ns, ppq: midi.ppq) < 0.08) { bass.insert(ch) }
        }

        func harmonySet(strict: Bool) -> Set<Int> {
            var set = Set<Int>()
            for (ch, ns) in byCh where ch != 9 && !bass.contains(ch) && ch != melody {
                let prog = midi.programs[ch] ?? 0
                if strict && !isStrictHarmony(prog) { continue }
                if !strict && (24...31).contains(prog) && polyphony(ns, ppq: midi.ppq) < 0.13 { continue }
                let starts = Dictionary(grouping: ns, by: { Int((Double($0.startTick) / Double(max(1, midi.ppq / 8))).rounded()) })
                let simultaneous = starts.values.filter { $0.count >= 2 }.count
                if simultaneous >= 2 || polyphony(ns, ppq: midi.ppq) >= 0.13 { set.insert(ch) }
            }
            return set
        }
        var harmony = harmonySet(strict: true)
        var fallback = false
        if harmony.isEmpty { harmony = harmonySet(strict: false); fallback = true }
        if harmony.isEmpty {
            harmony = Set(byCh.keys.filter { $0 != 9 && !bass.contains($0) && $0 != melody })
            fallback = true
        }

        let beat = midi.ticksPerBeat
        let quantum = max(1, beat)
        var boundaries: [(t: Int, pc: Int, w: Double, bass: Bool, delta: Double)] = []
        for n in notes where harmony.contains(n.channel) {
            let prog = midi.programs[n.channel] ?? 0
            let w = (0.6 + Double(n.velocity) / 127) * (isPadLike(prog) ? 2.1 : 1)
            boundaries.append((n.startTick, n.pitch % 12, w, false, 1))
            boundaries.append((n.endTick, n.pitch % 12, w, false, -1))
        }
        for n in notes where bass.contains(n.channel) {
            boundaries.append((n.startTick, n.pitch % 12, 0.85, true, 1))
            boundaries.append((n.endTick, n.pitch % 12, 0.85, true, -1))
        }
        boundaries.sort { $0.t != $1.t ? $0.t < $1.t : $0.delta < $1.delta }

        struct Slot { var t: Int; var to: Int; var chord: Chord?; var score: Double; var bass: [Double] }
        var timeline: [Slot] = []
        var activeH = [Double](repeating: 0, count: 12), activeB = [Double](repeating: 0, count: 12)
        var bi = 0
        var prev: Chord?
        let threshold = fallback ? 0.56 : 0.64
        var t = 0
        while t < midi.endTick {
            let to = min(midi.endTick, t + quantum)
            var w = [Double](repeating: 0, count: 12), bw = [Double](repeating: 0, count: 12)
            var at = t
            while bi < boundaries.count && boundaries[bi].t <= at {
                let e = boundaries[bi]; bi += 1
                if e.bass { activeB[e.pc] += e.delta * e.w } else { activeH[e.pc] += e.delta * e.w }
            }
            while at < to {
                let next = bi < boundaries.count ? min(to, boundaries[bi].t) : to
                let dt = Double(next - at)
                for k in 0..<12 { w[k] += max(0, activeH[k]) * dt; bw[k] += max(0, activeB[k]) * dt }
                at = next
                if at == to && (bi >= boundaries.count || boundaries[bi].t > at) { break }
                while bi < boundaries.count && boundaries[bi].t <= at {
                    let e = boundaries[bi]; bi += 1
                    if e.bass { activeB[e.pc] += e.delta * e.w } else { activeH[e.pc] += e.delta * e.w }
                }
            }
            // Il basso contribuisce anche al colore dell'accordo (poco).
            var mix = w
            for k in 0..<12 { mix[k] += bw[k] * 0.25 }
            let sum = mix.reduce(0, +)
            if sum <= 0 { timeline.append(Slot(t: t, to: to, chord: nil, score: 0, bass: bw)); t = to; continue }
            var best: Chord?
            var bestScore = -Double.infinity
            for r in 0..<12 {
                for q in templates {
                    let pcs = Set(q.intervals.map { ($0 + r) % 12 })
                    var hit = 0.0, extra = 0.0
                    for k in 0..<12 { if pcs.contains(k) { hit += mix[k] } else { extra += mix[k] } }
                    var score = hit / sum - extra / sum * 1.15
                    if bw[r] > 0 { score += 0.10 }
                    if let p = prev, p.root == r, p.quality == q { score += 0.085 }
                    score -= Double(max(0, q.intervals.count - 3)) * 0.013
                    // Una settima deve davvero suonare la settima.
                    if q.intervals.count == 4, mix[(q.intervals[3] + r) % 12] < 0.1 * sum { score -= 0.2 }
                    if score > bestScore { bestScore = score; best = Chord(root: r, quality: q) }
                }
            }
            let chord: Chord? = bestScore >= threshold ? best : nil
            timeline.append(Slot(t: t, to: to, chord: chord, score: bestScore, bass: bw))
            if let c = chord { prev = Chord(root: c.root, quality: c.quality) }
            t = to
        }

        func same(_ a: Chord?, _ b: Chord?) -> Bool {
            guard let a = a, let b = b else { return a == nil && b == nil }
            return a.root == b.root && a.quality == b.quality
        }
        // Livellamento: un accordo isolato tra due uguali viene assorbito.
        if timeline.count > 2 {
            for k in 1..<(timeline.count - 1) {
                if same(timeline[k-1].chord, timeline[k+1].chord) && !same(timeline[k-1].chord, timeline[k].chord) && timeline[k].score < 0.85 {
                    timeline[k].chord = timeline[k-1].chord
                }
            }
        }
        var regions: [ChordRegion] = []
        var regionBass: [[Double]] = []
        for s in timeline {
            if var last = regions.last, last.endTick == s.t, same(last.chord, s.chord) {
                last.endTick = s.to
                regions[regions.count - 1] = last
                for k in 0..<12 { regionBass[regionBass.count - 1][k] += s.bass[k] }
            } else {
                regions.append(ChordRegion(startTick: s.t, endTick: s.to, chord: s.chord))
                regionBass.append(s.bass)
            }
        }
        // Rivolto solo se, per tutto l'accordo, il basso tiene un'altra nota dell'accordo
        // e la fondamentale al basso è quasi assente (un basso che alterna 1 e 5 non è un rivolto).
        for i in regions.indices {
            guard var c = regions[i].chord else { continue }
            let bw = regionBass[i]
            let tot = bw.reduce(0, +)
            guard tot > 0, let bMax = bw.indices.max(by: { bw[$0] < bw[$1] }) else { continue }
            if bMax != c.root && c.pitchClasses.contains(bMax) && bw[bMax] / tot >= 0.7 && bw[c.root] / tot < 0.1 {
                c.bass = bMax
                regions[i].chord = c
            }
        }

        // Tonalità dalle durate di tutte le note non di batteria.
        var pc = [Double](repeating: 0, count: 12)
        for n in notes where n.channel != 9 { pc[n.pitch % 12] += max(0.05, Double(n.endTick - n.startTick) / Double(midi.ppq)) }
        let key = KeyDetector.detect(pc)

        return Analysis(regions: regions, key: key, melodyChannel: melody, bassChannels: bass, harmonyChannels: harmony, usedFallback: fallback)
    }

    /// Frazione del tempo in cui la traccia suona due o più note insieme.
    static func polyphony(_ ns: [MIDINote], ppq: Int) -> Double {
        var marks: [(Int, Int)] = []
        for n in ns { marks.append((n.startTick, 1)); marks.append((n.endTick, -1)) }
        marks.sort { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
        var count = 0, prevTick = marks.first?.0 ?? 0, overlap = 0, span = 0
        for (tick, d) in marks {
            if tick > prevTick {
                if count > 0 { span += tick - prevTick }
                if count >= 2 { overlap += tick - prevTick }
            }
            count += d; prevTick = tick
        }
        return span > 0 ? Double(overlap) / Double(span) : 0
    }

    static func events(_ regions: [ChordRegion], midi: MIDIFile) -> [ChordEvent] {
        var out: [ChordEvent] = []
        for r in regions {
            if let last = out.last, last.chord == r.chord { continue }
            out.append(ChordEvent(time: midi.seconds(atTick: r.startTick), chord: r.chord))
        }
        return out
    }
}

/// Trova la traccia della melodia: quella le cui note coincidono con le sillabe del testo,
/// altrimenti la traccia monofonica più "cantabile".
enum MelodyDetector {
    static func detect(_ midi: MIDIFile, lyrics: KaraokeLyrics?) -> Int? {
        let byCh = Dictionary(grouping: midi.notes.filter { $0.channel != 9 }, by: { $0.channel })
        if let lyr = lyrics, !lyr.isEmpty {
            let times = lyr.flat.map { $0.syllable.time }.filter { $0 >= 0 }
            if times.count >= 8 {
                var best: (ch: Int, score: Double)?
                for (ch, ns) in byCh {
                    let starts = ns.map { midi.seconds(atTick: $0.startTick) }.sorted()
                    var hits = 0
                    for t in times {
                        var lo = 0, hi = starts.count
                        while lo < hi { let m = (lo + hi) / 2; if starts[m] < t - 0.08 { lo = m + 1 } else { hi = m } }
                        if lo < starts.count && abs(starts[lo] - t) <= 0.08 { hits += 1 }
                    }
                    let recall = Double(hits) / Double(times.count)
                    let precision = Double(hits) / Double(max(1, starts.count))
                    let score = recall * 0.7 + min(1, precision * 1.5) * 0.3
                    if best == nil || score > best!.score { best = (ch, score) }
                }
                if let b = best, b.score > 0.35 { return b.ch }
            }
        }
        var best: (ch: Int, score: Double)?
        for (ch, ns) in byCh where ns.count >= 16 {
            let prog = midi.programs[ch] ?? 0
            if ChordEngine.isBassProgram(prog) { continue }
            let avg = Double(ns.map { $0.pitch }.reduce(0, +)) / Double(ns.count)
            let mono = 1 - ChordEngine.polyphony(ns, ppq: midi.ppq)
            let range = 1 - min(1, abs(avg - 67) / 18)
            var score = mono * 0.55 + range * 0.35 + min(1, Double(ns.count) / 300) * 0.1
            let name = (midi.trackNames[ns.first?.track ?? -1] ?? "").lowercased()
            if ["melod", "voce", "voice", "vocal", "canto", "lead", "melody"].contains(where: { name.contains($0) }) { score += 0.5 }
            if best == nil || score > best!.score { best = (ch, score) }
        }
        return best?.ch
    }
}
