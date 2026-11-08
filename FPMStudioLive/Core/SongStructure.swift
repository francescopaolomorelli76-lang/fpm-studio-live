import Foundation

/// Riconosce INTRO, VERSE, CHORUS, BRIDGE, SOLO e OUTRO.
/// Usa, in ordine di affidabilità: testo ripetuto (il ritornello ha le stesse parole),
/// sequenze di accordi ripetute, densità delle note e presenza della voce.
/// Il risultato si può sempre correggere a mano nel Piano Studio.
enum SongStructureAnalyzer {

    struct Input {
        var bars: [Double]                // inizio di ogni battuta (secondi)
        var duration: Double
        var musicStart: Double            // prima nota/suono
        var lyrics: KaraokeLyrics?
        var chords: [ChordEvent]
        var vocalTimes: [Double]          // attacchi della melodia (se non c'è testo)
        var density: [Double]             // energia/densità per battuta (stessa lunghezza di bars)
    }

    private struct Block {
        var firstBar: Int
        var lastBar: Int          // inclusivo
        var vocal: Bool
        var words: Set<String> = []
        var chords: [String] = []
        var density: Double = 0
        var kind: SectionKind = .verse
    }

    static func analyze(_ input: Input) -> [SongSection] {
        let bars = input.bars
        guard bars.count >= 4 else {
            return [SongSection(kind: .verse, start: 0, end: input.duration)]
        }
        let nBars = bars.count
        func barIndex(_ t: Double) -> Int {
            var lo = 0, hi = nBars - 1
            while lo < hi { let m = (lo + hi + 1) / 2; if bars[m] <= t + 0.02 { lo = m } else { hi = m - 1 } }
            return lo
        }
        func barEnd(_ i: Int) -> Double { i + 1 < nBars ? bars[i + 1] : input.duration }

        // Voce per battuta.
        var vocalCount = [Int](repeating: 0, count: nBars)
        let syllables = input.lyrics?.flat.map { $0.syllable }.filter { $0.time >= 0 } ?? []
        let vocalTimes = syllables.isEmpty ? input.vocalTimes : syllables.map { $0.time }
        for t in vocalTimes { vocalCount[barIndex(t)] += 1 }

        // Accordo prevalente per battuta.
        var barChords = [String](repeating: "-", count: nBars)
        if !input.chords.isEmpty {
            var ci = 0
            for b in 0..<nBars {
                let mid = bars[b] + (barEnd(b) - bars[b]) * 0.25
                while ci + 1 < input.chords.count && input.chords[ci + 1].time <= mid { ci += 1 }
                if let c = input.chords[ci].chord { barChords[b] = "\(c.root):\(c.quality.rawValue)" }
            }
        }

        guard let firstVocal = vocalCount.firstIndex(where: { $0 > 0 }),
              let lastVocal = vocalCount.lastIndex(where: { $0 > 0 }) else {
            return chordOnlySections(input, barChords: barChords)
        }

        var blocks: [Block] = []
        let startBar = barIndex(input.musicStart)
        if firstVocal > startBar { blocks.append(Block(firstBar: startBar, lastBar: firstVocal - 1, vocal: false, kind: .intro)) }

        // Confini delle strofe: paragrafi del testo, altrimenti pause della voce.
        var cuts: [Int] = [firstVocal]
        if let lyr = input.lyrics, lyr.lines.contains(where: { $0.endsParagraph }) {
            for (i, l) in lyr.lines.enumerated() where l.endsParagraph && i + 1 < lyr.lines.count {
                let st = lyr.lines[i + 1].startTime
                if st >= 0 { cuts.append(barIndex(st + 0.15)) }
            }
        } else {
            var b = firstVocal
            var since = 0
            while b <= lastVocal {
                if vocalCount[b] == 0 {
                    var e = b
                    while e <= lastVocal && vocalCount[e] == 0 { e += 1 }
                    if since >= 6 || e - b >= 2 { cuts.append(e); since = 0 }
                    b = e
                } else {
                    since += 1
                    if since >= 8 && (b + 1) <= lastVocal && (b + 1 - firstVocal) % 4 == 0 { cuts.append(b + 1); since = 0 }
                    b += 1
                }
            }
        }
        cuts = Array(Set(cuts.filter { $0 >= firstVocal && $0 <= lastVocal })).sorted()
        for (i, c) in cuts.enumerated() {
            let end = i + 1 < cuts.count ? cuts[i + 1] - 1 : lastVocal
            if end < c { continue }
            // Pausa strumentale lunga dentro il blocco: la separo.
            var vocalEnd = end
            while vocalEnd > c && vocalCount[vocalEnd] == 0 { vocalEnd -= 1 }
            if end - vocalEnd >= 3 {
                blocks.append(Block(firstBar: c, lastBar: vocalEnd, vocal: true))
                blocks.append(Block(firstBar: vocalEnd + 1, lastBar: end, vocal: false, kind: .instrumental))
            } else {
                blocks.append(Block(firstBar: c, lastBar: end, vocal: true))
            }
        }
        if lastVocal + 1 < nBars {
            let musicEnd = barIndex(max(0, input.duration - 0.5))
            if musicEnd > lastVocal { blocks.append(Block(firstBar: lastVocal + 1, lastBar: nBars - 1, vocal: false, kind: .outro)) }
        }

        // Caratteristiche.
        for i in blocks.indices {
            let b = blocks[i]
            let t0 = bars[b.firstBar], t1 = barEnd(b.lastBar)
            var words = Set<String>()
            for s in syllables where s.time >= t0 - 0.1 && s.time < t1 - 0.1 {
                words.insert(s.text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)))
            }
            // Le parole si ricompongono: uso anche coppie di sillabe consecutive.
            blocks[i].words = words.filter { $0.count >= 2 }
            blocks[i].chords = Array(barChords[b.firstBar...b.lastBar])
            let d = input.density.isEmpty ? [0.0] : Array(input.density[b.firstBar...min(b.lastBar, input.density.count - 1)])
            blocks[i].density = d.reduce(0, +) / Double(max(1, d.count))
        }

        let vocalIdx = blocks.indices.filter { blocks[$0].vocal }
        func lyricSim(_ a: Block, _ b: Block) -> Double {
            guard !a.words.isEmpty, !b.words.isEmpty else { return 0 }
            return Double(a.words.intersection(b.words).count) / Double(a.words.union(b.words).count)
        }
        func chordSim(_ a: Block, _ b: Block) -> Double {
            let n = min(a.chords.count, b.chords.count)
            guard n > 0 else { return 0 }
            var eq = 0
            for k in 0..<n where a.chords[k] == b.chords[k] && a.chords[k] != "-" { eq += 1 }
            return Double(eq) / Double(max(a.chords.count, b.chords.count))
        }
        let hasLyrics = !syllables.isEmpty

        // Gruppi di blocchi simili.
        var group = [Int: Int]()
        var groups: [[Int]] = []
        for i in vocalIdx {
            if group[i] != nil { continue }
            var g = [i]
            group[i] = groups.count
            for j in vocalIdx where j > i && group[j] == nil {
                let s = hasLyrics ? max(lyricSim(blocks[i], blocks[j]), chordSim(blocks[i], blocks[j]) * 0.6) : chordSim(blocks[i], blocks[j])
                if s >= (hasLyrics ? 0.45 : 0.7) { g.append(j); group[j] = groups.count }
            }
            groups.append(g)
        }
        // Ritornello: il gruppo più ripetuto (a parità, il più denso e il più tardivo a comparire per primo).
        let repeated = groups.filter { $0.count >= 2 }
        let chorusGroup = repeated.max { a, b in
            if a.count != b.count { return a.count < b.count }
            let da = a.map { blocks[$0].density }.reduce(0, +) / Double(a.count)
            let db = b.map { blocks[$0].density }.reduce(0, +) / Double(b.count)
            return da < db
        }
        let chorusSet = Set(chorusGroup ?? [])
        let firstChorus = chorusSet.min() ?? Int.max
        let secondChorus = chorusSet.sorted().dropFirst().first ?? Int.max
        for i in vocalIdx {
            if chorusSet.contains(i) { blocks[i].kind = .chorus; continue }
            let g = groups[group[i] ?? 0]
            let unique = g.count == 1
            let verseLike = vocalIdx.contains { j in j != i && !chorusSet.contains(j) && chordSim(blocks[i], blocks[j]) >= 0.5 }
            if unique && i > secondChorus && !verseLike { blocks[i].kind = .bridge }
            else if unique && i > firstChorus && !verseLike && chorusSet.count >= 2 && i > firstChorus + 1 { blocks[i].kind = .bridge }
            else { blocks[i].kind = .verse }
        }
        // Pre-ritornello: blocco corto subito prima di un ritornello, ripetuto.
        for i in vocalIdx where blocks[i].kind == .verse && i + 1 < blocks.count && blocks[i + 1].kind == .chorus {
            let len = blocks[i].lastBar - blocks[i].firstBar + 1
            let g = groups[group[i] ?? 0]
            if len <= 4 && g.count >= 2 && g.allSatisfy({ $0 + 1 < blocks.count && blocks[$0 + 1].kind == .chorus }) {
                for j in g { blocks[j].kind = .preChorus }
            }
        }

        // Unisco blocchi consecutivi dello stesso tipo e numero le sezioni.
        var merged: [Block] = []
        for b in blocks {
            if var last = merged.last, last.kind == b.kind, last.lastBar + 1 == b.firstBar, b.kind != .intro {
                last.lastBar = b.lastBar
                merged[merged.count - 1] = last
            } else { merged.append(b) }
        }
        var counters: [SectionKind: Int] = [:]
        var out: [SongSection] = []
        for b in merged {
            counters[b.kind, default: 0] += 1
            out.append(SongSection(kind: b.kind, start: bars[b.firstBar], end: barEnd(b.lastBar), number: counters[b.kind]!))
        }
        if let f = out.first, f.start > 0.01 { out[0].start = min(f.start, input.musicStart) }
        if !out.isEmpty { out[out.count - 1].end = input.duration }
        return out
    }

    /// Senza voce né testo: frasi di 8 battute; il ritornello è la frase ripetuta con più energia,
    /// l'intro/il finale sono le parti iniziali/finali più deboli.
    private static func chordOnlySections(_ input: Input, barChords: [String]) -> [SongSection] {
        let n = input.bars.count
        let phrase = n > 48 ? 8 : 4
        let dens = input.density.count == n ? input.density : [Double](repeating: 1, count: n)
        struct P { var a: Int; var b: Int; var sig: String; var e: Double }
        var ps: [P] = []
        var b = 0
        // Intro: battute iniziali sotto il 60% dell'energia media.
        let mean = dens.reduce(0, +) / Double(max(1, n))
        var introEnd = 0
        while introEnd < min(8, n) && dens[introEnd] < mean * 0.6 { introEnd += 1 }
        if introEnd >= 2 { ps.append(P(a: 0, b: introEnd - 1, sig: "intro", e: 0)); b = introEnd }
        while b < n {
            let e = min(n - 1, b + phrase - 1)
            let en = dens[b...e].reduce(0, +) / Double(e - b + 1)
            ps.append(P(a: b, b: e, sig: barChords[b...e].joined(separator: ","), e: en))
            b = e + 1
        }
        var counts: [String: Int] = [:]
        for p in ps { counts[p.sig, default: 0] += 1 }
        let repeatedE = ps.filter { $0.sig != "intro" && (counts[$0.sig] ?? 0) >= 2 }.map { $0.e }
        let threshold = repeatedE.isEmpty ? mean * 1.05 : (repeatedE.reduce(0, +) / Double(repeatedE.count))
        var out: [SongSection] = []
        var counters: [SectionKind: Int] = [:]
        for (i, p) in ps.enumerated() {
            let kind: SectionKind
            if p.sig == "intro" { kind = .intro }
            else if i == ps.count - 1 && p.e < mean * 0.75 && ps.count > 3 { kind = .outro }
            else if p.e >= threshold * 1.02 { kind = .chorus }
            else { kind = .verse }
            if let last = out.last, last.kind == kind, kind != .intro {
                out[out.count - 1].end = p.b + 1 < n ? input.bars[p.b + 1] : input.duration
                continue
            }
            counters[kind, default: 0] += 1
            out.append(SongSection(kind: kind, start: input.bars[p.a], end: p.b + 1 < n ? input.bars[p.b + 1] : input.duration, number: counters[kind]!))
        }
        if !out.isEmpty { out[0].start = 0; out[out.count - 1].end = input.duration }
        return out
    }

    // MARK: - Marker del produttore (basi M-Live e altre)

    /// Se il MIDI contiene i marker di struttura ("Intro", "Verse 1", "Chorus 1", "Coda", "Fine"…) li usa così come sono.
    static func fromMarkers(_ midi: MIDIFile) -> [SongSection]? {
        var marks: [(t: Double, name: String)] = []
        for e in midi.events {
            if case .meta(let type, let data) = e.kind, type == 0x06 {
                let n = TextDecoding.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { marks.append((midi.seconds(atTick: e.tick), n)) }
            }
        }
        guard marks.count >= 3 else { return nil }
        func kind(_ n: String, next: String?) -> SectionKind? {
            let l = n.lowercased()
            if l.hasPrefix("intro") { return .intro }
            if l.hasPrefix("verse") || l.hasPrefix("strofa") || l.hasPrefix("vers") { return .verse }
            if l.hasPrefix("pre") { return .preChorus }
            if l.hasPrefix("bridge") || l.hasPrefix("ponte") {
                // Nelle basi italiane il "Bridge" tra strofa e ritornello è un pre-ritornello.
                if let nx = next?.lowercased(), nx.hasPrefix("chorus") || nx.hasPrefix("rit") { return .preChorus }
                return .bridge
            }
            if l.hasPrefix("chorus") || l.hasPrefix("rit") || l.hasPrefix("refrain") { return .chorus }
            if l.hasPrefix("special") { return .bridge }
            if l.hasPrefix("instr") || l.hasPrefix("interl") || l.hasPrefix("solo") || l.hasPrefix("strum") { return .instrumental }
            if l.hasPrefix("coda") || l.hasPrefix("outro") || l.hasPrefix("finale") || l.hasPrefix("ending") { return .outro }
            return nil
        }
        var out: [SongSection] = []
        var counters: [SectionKind: Int] = [:]
        for (i, m) in marks.enumerated() {
            let l = m.name.lowercased()
            if l == "fine" || l == "end" { if !out.isEmpty { out[out.count - 1].end = m.t }; continue }
            guard let k = kind(m.name, next: i + 1 < marks.count ? marks[i + 1].name : nil) else { continue }
            let end = i + 1 < marks.count ? marks[i + 1].t : midi.duration
            counters[k, default: 0] += 1
            out.append(SongSection(kind: k, start: m.t, end: end, number: counters[k]!, label: m.name))
        }
        guard out.count >= 2 else { return nil }
        if out[0].start > 0.5 { out[0].start = 0 }
        if let last = out.last, last.end < midi.duration - 0.5, marks.last?.name.lowercased() != "fine" { out[out.count - 1].end = midi.duration }
        return out
    }

    // MARK: - Ingresso dal MIDI

    static func input(midi: MIDIFile, lyrics: KaraokeLyrics?, chords: [ChordEvent], melodyChannel: Int?) -> Input {
        var bars: [Double] = []
        var tick = 0
        // Battute seguendo eventuali cambi di metrica.
        let sigs = midi.timeSignatures.isEmpty ? [(tick: 0, num: 4, den: 4)] : midi.timeSignatures
        var si = 0
        while tick <= midi.endTick {
            while si + 1 < sigs.count && sigs[si + 1].tick <= tick { si += 1 }
            bars.append(midi.seconds(atTick: tick))
            let s = sigs[si]
            tick += max(1, midi.ppq * 4 / max(1, s.den) * max(1, s.num))
        }
        var density = [Double](repeating: 0, count: bars.count)
        for n in midi.notes {
            let t = midi.seconds(atTick: n.startTick)
            var lo = 0, hi = bars.count - 1
            while lo < hi { let m = (lo + hi + 1) / 2; if bars[m] <= t { lo = m } else { hi = m - 1 } }
            density[lo] += Double(n.velocity) / 127
        }
        let melodyTimes = midi.notes.filter { $0.channel == melodyChannel }.map { midi.seconds(atTick: $0.startTick) }
        let start = midi.notes.first.map { midi.seconds(atTick: $0.startTick) } ?? 0
        return Input(bars: bars, duration: midi.duration, musicStart: start, lyrics: lyrics, chords: chords,
                     vocalTimes: melodyTimes, density: density)
    }
}
