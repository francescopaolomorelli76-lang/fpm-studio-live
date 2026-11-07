import Foundation

// MARK: - AI Studio: generatore musicale locale, gratuito e illimitato.
//
// Non usa servizi in rete: compone accordi, struttura, arrangiamento (batteria, basso,
// accompagnamento, archi/pad, melodia guida) e testo karaoke sincronizzato secondo lo stile
// scelto. Con una traccia di riferimento (MIDI o MP3) ne conserva accordi, tempo e struttura
// e la riarrangia nello stile richiesto.

enum MusicStyle: String, CaseIterable, Identifiable, Codable {
    case pop, rock, pianoBallad, acoustic, dance, house, lofi, jazz, bossa, latin, reggaeton, soul, country, cinematic, waltz, liscio
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pop: return "Pop"
        case .rock: return "Rock"
        case .pianoBallad: return "Piano Ballad"
        case .acoustic: return "Acoustic"
        case .dance: return "Dance"
        case .house: return "House"
        case .lofi: return "Lo-fi"
        case .jazz: return "Jazz"
        case .bossa: return "Bossa Nova"
        case .latin: return "Latin"
        case .reggaeton: return "Reggaeton"
        case .soul: return "Soul / R&B"
        case .country: return "Country / Folk"
        case .cinematic: return "Cinematic"
        case .waltz: return "Valzer"
        case .liscio: return "Liscio"
        }
    }
    var defaultBPM: Double {
        switch self {
        case .pop: return 104
        case .rock: return 122
        case .pianoBallad: return 72
        case .acoustic: return 96
        case .dance: return 124
        case .house: return 124
        case .lofi: return 82
        case .jazz: return 132
        case .bossa: return 128
        case .latin: return 100
        case .reggaeton: return 94
        case .soul: return 88
        case .country: return 110
        case .cinematic: return 76
        case .waltz: return 150
        case .liscio: return 168
        }
    }
    var beatsPerBar: Int { self == .waltz || self == .liscio ? 3 : 4 }

    /// Riconosce lo stile da parole chiave libere ("cinematic, orchestral, lo-fi chill").
    static func fromText(_ text: String) -> [MusicStyle] {
        let t = text.lowercased()
        let keys: [(String, MusicStyle)] = [
            ("ballad", .pianoBallad), ("ballata", .pianoBallad), ("piano", .pianoBallad), ("rock", .rock), ("metal", .rock),
            ("acoustic", .acoustic), ("acustic", .acoustic), ("folk", .country), ("country", .country), ("edm", .dance),
            ("dance", .dance), ("techno", .house), ("house", .house), ("trance", .dance), ("synthwave", .dance),
            ("lo-fi", .lofi), ("lofi", .lofi), ("chill", .lofi), ("hip-hop", .lofi), ("hip hop", .lofi), ("trap", .reggaeton),
            ("jazz", .jazz), ("swing", .jazz), ("bossa", .bossa), ("latin", .latin), ("salsa", .latin), ("reggaeton", .reggaeton),
            ("soul", .soul), ("r&b", .soul), ("gospel", .soul), ("funk", .soul), ("cinematic", .cinematic), ("orchestr", .cinematic),
            ("epic", .cinematic), ("classical", .cinematic), ("classic", .cinematic), ("valzer", .waltz), ("waltz", .waltz),
            ("liscio", .liscio), ("mazurka", .liscio), ("pop", .pop)
        ]
        var out: [MusicStyle] = []
        for (k, s) in keys where t.contains(k) && !out.contains(s) { out.append(s) }
        return out
    }
}

enum Instrument: String, CaseIterable, Identifiable, Codable {
    case drums, bass, piano, guitar, strings, pad, brass, lead
    var id: String { rawValue }
    var label: String {
        switch self {
        case .drums: return "Batteria"
        case .bass: return "Basso"
        case .piano: return "Pianoforte / tastiere"
        case .guitar: return "Chitarra"
        case .strings: return "Archi"
        case .pad: return "Synth / pad"
        case .brass: return "Fiati"
        case .lead: return "Melodia guida"
        }
    }
    static func fromNegativeText(_ text: String) -> Set<Instrument> {
        let t = text.lowercased()
        var s = Set<Instrument>()
        if t.contains("drum") || t.contains("batter") || t.contains("percuss") { s.insert(.drums) }
        if t.contains("bass") { s.insert(.bass) }
        if t.contains("piano") || t.contains("tastier") || t.contains("keys") { s.insert(.piano) }
        if t.contains("guitar") || t.contains("chitarr") { s.insert(.guitar) }
        if t.contains("string") || t.contains("archi") || t.contains("violin") || t.contains("orchestr") { s.insert(.strings) }
        if t.contains("synth") || t.contains("pad") || t.contains("electronic") || t.contains("edm") { s.insert(.pad) }
        if t.contains("brass") || t.contains("fiati") || t.contains("sax") || t.contains("tromb") { s.insert(.brass) }
        return s
    }
}

struct GeneratorRequest: Codable {
    enum Source: String, Codable { case scratch, reference }
    enum Vocal: String, Codable { case instrumental, guideMelody }

    var title = ""
    var tags = ""
    var source: Source = .scratch
    /// Durata in secondi; 0 = automatica (dal testo o dall'originale).
    var duration: Double = 60
    var vocal: Vocal = .instrumental
    var styleText = ""
    var styles: [MusicStyle] = [.pop]
    var bpm: Double? = nil               // nil = automatico
    var keyRoot: Int? = nil              // nil = automatico
    var minor: Bool? = nil
    var variety = 1                      // 0 bassa, 1 normale, 2 alta
    var negativeText = ""
    var styleWeight = 0.5                // 0 neutro … 1 massimo carattere dello stile
    var strangeness = 0.5                // 0 prevedibile … 1 sperimentale
    var referenceWeight = 0.5            // 0 accordi nuovi … 1 accordi del riferimento
    var lyrics = ""
    var seed: UInt64 = 1
}

/// Riferimento estratto da un MIDI o da un MP3.
struct ReferenceTrack {
    var bpm: Double
    var beatsPerBar: Int
    var keyRoot: Int
    var minor: Bool
    var duration: Double
    var barChords: [Chord?]              // un accordo per battuta
    var sections: [SongSection]
    var lyrics: KaraokeLyrics?
}

struct GeneratedSong {
    var midi: Data
    var lyrics: KaraokeLyrics
    var chords: [ChordEvent]
    var sections: [SongSection]
    var bpm: Double
    var keyRoot: Int
    var minor: Bool
    var styleLabel: String
    var summary: String
}

struct SongGenerator {
    var req: GeneratorRequest
    var reference: ReferenceTrack?

    private struct RNG {
        var s: UInt64
        mutating func next() -> Double {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s % 1_000_000) / 1_000_000
        }
        mutating func chance(_ p: Double) -> Bool { next() < p }
        mutating func pick<T>(_ a: [T]) -> T { a[min(a.count - 1, Int(next() * Double(a.count)))] }
        mutating func int(_ a: Int, _ b: Int) -> Int { a + min(b - a, Int(next() * Double(b - a + 1))) }
    }

    private struct Block {
        var kind: SectionKind
        var bars: Int
        var lines: [String] = []
        var chords: [Chord] = []          // uno per battuta (o due per battuta nei cambi veloci, qui uno)
        var number = 1
    }

    static let ppq = 480

    func generate() -> GeneratedSong {
        var rng = RNG(s: req.seed &* 2862933555777941757 &+ 3037000493 | 1)
        let style = req.styles.first ?? MusicStyle.fromText(req.styleText).first ?? .pop
        let excluded = Instrument.fromNegativeText(req.negativeText)
        let ref = req.source == .reference ? reference : nil
        let bpb = ref?.beatsPerBar ?? style.beatsPerBar
        let bpm = req.bpm ?? ref?.bpm ?? style.defaultBPM * (req.variety == 2 ? (0.94 + rng.next() * 0.12) : 1)
        let minor = req.minor ?? ref?.minor ?? ([.pianoBallad, .cinematic, .reggaeton, .lofi].contains(style) ? rng.chance(0.55) : rng.chance(0.25))
        let key = req.keyRoot ?? ref?.keyRoot ?? rng.pick(minor ? [9, 4, 2, 7, 0] : [0, 7, 2, 5, 9, 4])
        let barSec = 60 / bpm * Double(bpb)

        // 1. Struttura.
        var blocks = makeForm(style: style, barSec: barSec, ref: ref, rng: &rng)

        // 2. Accordi.
        assignChords(&blocks, style: style, key: key, minor: minor, ref: ref, barSec: barSec, rng: &rng)

        // 3. Arrangiamento.
        let tpb = SongGenerator.ppq
        let barT = tpb * bpb
        var tracks: [String: [MIDIWriter.TrackEvent]] = [:]
        var conductor: [MIDIWriter.TrackEvent] = [
            .init(tick: 0, bytes: MIDIWriter.tempo(bpm: bpm)),
            .init(tick: 0, bytes: MIDIWriter.meta(0x58, [UInt8(bpb), 2, 24, 8])),
            .init(tick: 0, bytes: MIDIWriter.text(0x03, req.title.isEmpty ? "FPM AI Studio" : req.title))
        ]
        let parts = instrumentation(style).filter { !excluded.contains($0.inst) }
        for p in parts {
            tracks[p.name] = [
                .init(tick: 0, bytes: [0xB0 | p.ch, 0, p.ch == 9 ? 0 : 0]),
                .init(tick: 0, bytes: [0xC0 | p.ch, p.program]),
                .init(tick: 0, bytes: [0xB0 | p.ch, 7, p.volume]),
                .init(tick: 0, bytes: [0xB0 | p.ch, 10, p.pan]),
                .init(tick: 0, bytes: [0xB0 | p.ch, 91, p.reverb])
            ]
        }
        var lyrics = KaraokeLyrics(title: req.title.isEmpty ? nil : req.title, artist: "FPM AI Studio", lines: [])
        var sections: [SongSection] = []
        var chordEvents: [ChordEvent] = []
        var bar = 0
        var prevVoicing = [60, 64, 67]
        var counters: [SectionKind: Int] = [:]
        let swing = [.jazz, .lofi, .soul].contains(style) ? 0.16 + 0.1 * req.styleWeight : 0
        func sw(_ t: Int) -> Int {
            // Swing sulle crome in levare.
            guard swing > 0 else { return t }
            let e = tpb / 2
            return (t / e) % 2 == 1 ? t + Int(Double(e) * swing) : t
        }
        let secondsPerTick = 60 / bpm / Double(tpb)

        for (bi, b) in blocks.enumerated() {
            counters[b.kind, default: 0] += 1
            let startTick = bar * barT
            sections.append(SongSection(kind: b.kind, start: Double(startTick) * secondsPerTick,
                                        end: Double((bar + b.bars) * barT) * secondsPerTick, number: counters[b.kind]!))
            let intensity: Double = {
                switch b.kind {
                case .intro: return 0.55
                case .verse: return 0.7
                case .preChorus: return 0.8
                case .chorus: return 1.0
                case .bridge: return 0.75
                case .instrumental: return 0.9
                case .outro: return 0.55
                }
            }()
            for k in 0..<b.bars {
                let t0 = (bar + k) * barT
                let c = b.chords[min(k, b.chords.count - 1)]
                if chordEvents.last?.chord != c { chordEvents.append(ChordEvent(time: Double(t0) * secondsPerTick, chord: c)) }
                let lastBarOfBlock = k == b.bars - 1
                let isFinal = bi == blocks.count - 1 && lastBarOfBlock
                for p in parts {
                    var evs = tracks[p.name] ?? []
                    switch p.inst {
                    case .drums:
                        drums(&evs, style: style, t0: t0, bpb: bpb, intensity: intensity, fill: lastBarOfBlock && !isFinal,
                              crash: k == 0 && (b.kind == .chorus || bi > 0), final: isFinal, kind: b.kind, sw: sw, rng: &rng)
                    case .bass:
                        let next = k + 1 < b.chords.count ? b.chords[k + 1] : (bi + 1 < blocks.count ? blocks[bi + 1].chords.first ?? c : c)
                        bassLine(&evs, ch: p.ch, style: style, chord: c, next: next, t0: t0, bpb: bpb, intensity: intensity, final: isFinal, sw: sw, rng: &rng)
                    case .piano, .guitar:
                        let v = PianoArranger.voicing(for: c, previous: prevVoicing, rich: style == .jazz || style == .bossa || style == .soul || style == .lofi,
                                                      low: p.inst == .guitar ? 52 : 55, high: p.inst == .guitar ? 76 : 79)
                        if p.inst == .piano || !parts.contains(where: { $0.inst == .piano }) { prevVoicing = v }
                        comp(&evs, part: p, style: style, voicing: v, chord: c, t0: t0, bpb: bpb, intensity: intensity, kind: b.kind, final: isFinal, sw: sw, rng: &rng)
                    case .strings, .pad, .brass:
                        let on = p.inst == .pad ? (b.kind != .intro || style == .cinematic || style == .lofi)
                            : p.inst == .strings ? (b.kind == .chorus || b.kind == .bridge || b.kind == .outro || style == .cinematic || style == .pianoBallad && b.kind != .intro)
                            : (b.kind == .chorus && (k % 2 == 1))
                        if on {
                            let v = PianoArranger.voicing(for: c, previous: prevVoicing, rich: false, low: p.inst == .strings ? 55 : 60, high: p.inst == .strings ? 81 : 79)
                            let vel = UInt8(Double(p.inst == .brass ? 92 : 70) * (0.75 + 0.25 * intensity))
                            if p.inst == .brass {
                                for n in v { addNote(&evs, p.ch, n, t0 + tpb * (bpb - 1) + tpb / 2, tpb / 2 - 20, vel) }
                            } else {
                                for n in v { addNote(&evs, p.ch, n, t0, barT * (isFinal ? 2 : 1) - 10, vel) }
                                if p.inst == .strings && b.kind == .chorus { addNote(&evs, p.ch, (v.first ?? 60) - 12, t0, barT - 10, vel) }
                            }
                        }
                    case .lead: break
                    }
                    tracks[p.name] = evs
                }
            }
            // 4. Melodia guida e testo karaoke.
            if !b.lines.isEmpty {
                let lead = parts.first { $0.inst == .lead }
                var evs = lead.map { tracks[$0.name] ?? [] } ?? []
                let barsPerLine = max(1, b.bars / max(1, b.lines.count))
                for (li, line) in b.lines.enumerated() {
                    let lineStartBar = bar + li * barsPerLine
                    let chordsForLine = (0..<barsPerLine).map { b.chords[min(b.chords.count - 1, li * barsPerLine + $0)] }
                    let syl = Syllabifier.syllables(line)
                    let melody = melodyFor(syllables: syl, chords: chordsForLine, startTick: lineStartBar * barT, bpb: bpb,
                                           key: key, minor: minor, kind: b.kind, lineIndex: li, rng: &rng)
                    var ll = LyricLine()
                    for (si, s) in syl.enumerated() where si < melody.count {
                        let m = melody[si]
                        if let lp = lead { addNote(&evs, lp.ch, m.pitch, m.tick, m.dur, 96) }
                        ll.syllables.append(LyricSyllable(text: s.text, time: Double(m.tick) * secondsPerTick))
                    }
                    ll.endsParagraph = li == b.lines.count - 1
                    if !ll.syllables.isEmpty { lyrics.lines.append(ll) }
                }
                if let lp = lead { tracks[lp.name] = evs }
            }
            bar += b.bars
        }
        // Accordo finale tenuto + rallentando nell'ultima battuta.
        let endTick = bar * barT
        conductor.append(.init(tick: max(0, endTick - barT), bytes: MIDIWriter.tempo(bpm: bpm * 0.9)))
        conductor.append(.init(tick: max(0, endTick - barT / 2), bytes: MIDIWriter.tempo(bpm: bpm * 0.78)))
        if req.vocal == .guideMelody || !req.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conductor += MIDIFile.lyricEventsFromTicks(lyrics, secondsPerTick: secondsPerTick)
        }
        var w = MIDIWriter(ppq: tpb)
        w.addTrack("Tempo", conductor)
        for p in parts { if let evs = tracks[p.name], evs.count > 5 { w.addTrack(p.name, evs) } }
        let excludedText = excluded.isEmpty ? "" : " · senza " + excluded.map { $0.label.lowercased() }.sorted().joined(separator: ", ")
        let summary = "\(style.label) · \(Int(bpm.rounded())) BPM · \(KeyDetector.name(root: key, minor: minor, notation: .italian)) · " +
            "\(bar) battute (\(Int((Double(bar) * barSec).rounded())) s)" + excludedText
        return GeneratedSong(midi: w.data(), lyrics: lyrics, chords: chordEvents, sections: sections, bpm: bpm,
                             keyRoot: key, minor: minor, styleLabel: style.label, summary: summary)
    }

    // MARK: Forma

    private func makeForm(style: MusicStyle, barSec: Double, ref: ReferenceTrack?, rng: inout RNG) -> [Block] {
        // Con riferimento: stessa struttura dell'originale (eventualmente accorciata).
        if let r = ref, !r.sections.isEmpty {
            var blocks: [Block] = []
            for s in r.sections {
                let bars = max(1, Int(((s.end - s.start) / barSec).rounded()))
                blocks.append(Block(kind: s.kind, bars: bars))
            }
            if req.duration > 0 { blocks = trim(blocks, toBars: Int(req.duration / barSec)) }
            return attachLyrics(blocks)
        }
        // Dal testo: una sezione per strofa, il ritornello è la strofa che si ripete.
        let paragraphs = SongGenerator.paragraphs(req.lyrics)
        if !paragraphs.isEmpty {
            var blocks: [Block] = [Block(kind: .intro, bars: style == .pianoBallad || style == .cinematic ? 4 : 2)]
            var seen: [String: Int] = [:]
            for p in paragraphs { seen[p.text.joined(separator: "\n").lowercased(), default: 0] += 1 }
            var hadChorus = false
            var verses = 0
            for (i, p) in paragraphs.enumerated() {
                let keyText = p.text.joined(separator: "\n").lowercased()
                var kind: SectionKind = p.label ?? ((seen[keyText] ?? 0) > 1 ? .chorus : .verse)
                if kind == .verse && hadChorus && verses >= 2 && i == paragraphs.count - 2 && (seen[keyText] ?? 0) == 1 { kind = .bridge }
                if kind == .chorus { hadChorus = true } else if kind == .verse { verses += 1 }
                // Ogni verso dura circa 3,5–5 secondi, in numero pari di battute.
                var barsPerLine = Int((4.2 / barSec).rounded()).clamped(2, 4)
                if barsPerLine == 3 { barsPerLine = 4 }
                if p.text.count <= 2 { barsPerLine = min(4, barsPerLine * 2) }
                var bars = p.text.count * barsPerLine
                bars = max(4, Int((Double(bars) / 4).rounded(.up)) * 4)
                var b = Block(kind: kind, bars: bars)
                b.lines = p.text
                blocks.append(b)
                if kind == .chorus && i + 1 < paragraphs.count && style != .pianoBallad && rng.chance(0.3) {
                    blocks.append(Block(kind: .instrumental, bars: 4))
                }
            }
            blocks.append(Block(kind: .outro, bars: style == .pianoBallad ? 4 : 4))
            if req.duration > 0 && Double(blocks.map { $0.bars }.reduce(0, +)) * barSec > req.duration * 1.15 {
                blocks = trim(blocks, toBars: Int(req.duration / barSec))
            }
            return blocks
        }
        // Da zero, senza testo: forma standard adattata alla durata.
        let total = req.duration > 0 ? max(4, Int((req.duration / barSec).rounded())) : Int(150 / barSec)
        let template: [(SectionKind, Int)] = [(.intro, 4), (.verse, 8), (.chorus, 8), (.verse, 8), (.chorus, 8), (.bridge, 8), (.chorus, 8), (.outro, 4)]
        if total <= 6 { return [Block(kind: .chorus, bars: max(2, total))] }
        if total <= 12 { return [Block(kind: .intro, bars: 2), Block(kind: .chorus, bars: total - 4), Block(kind: .outro, bars: 2)] }
        if total <= 22 { return [Block(kind: .intro, bars: 2), Block(kind: .verse, bars: 8), Block(kind: .chorus, bars: total - 12), Block(kind: .outro, bars: 2)] }
        var blocks = template.map { Block(kind: $0.0, bars: $0.1) }
        var sum = blocks.map { $0.bars }.reduce(0, +)
        // Allunga ripetendo il ritornello o accorcia togliendo sezioni centrali.
        while sum + 8 <= total { blocks.insert(Block(kind: .chorus, bars: 8), at: blocks.count - 1); sum += 8 }
        blocks = trim(blocks, toBars: total)
        return blocks
    }

    private func trim(_ blocks: [Block], toBars target: Int) -> [Block] {
        var b = blocks
        var sum = b.map { $0.bars }.reduce(0, +)
        // Rimuovo prima ponte, poi strofe/ritornelli dal centro, mantenendo intro, un ritornello e il finale.
        while sum > target && b.count > 3 {
            let order: [SectionKind] = [.instrumental, .bridge, .verse, .preChorus, .chorus]
            var removed = false
            for k in order {
                let idx = b.indices.filter { b[$0].kind == k }
                if (k == .chorus && idx.count <= 1) { continue }
                if let i = (k == .verse ? idx.dropFirst().last ?? idx.last : idx.last), i > 0, i < b.count - 1 {
                    sum -= b[i].bars; b.remove(at: i); removed = true; break
                }
            }
            if !removed { break }
        }
        if sum > target, let i = b.indices.max(by: { b[$0].bars < b[$1].bars }) {
            b[i].bars = max(2, b[i].bars - (sum - target))
        }
        return b
    }

    private func attachLyrics(_ blocks: [Block]) -> [Block] {
        let paragraphs = SongGenerator.paragraphs(req.lyrics)
        guard !paragraphs.isEmpty else { return blocks }
        var b = blocks
        var pi = 0
        for i in b.indices where [.verse, .chorus, .bridge, .preChorus].contains(b[i].kind) && pi < paragraphs.count {
            b[i].lines = paragraphs[pi].text; pi += 1
        }
        return b
    }

    struct Paragraph { var text: [String]; var label: SectionKind? }

    /// Divide il testo in strofe. Accetta etichette come [Chorus], Rit., Strofa, Bridge.
    static func paragraphs(_ text: String) -> [Paragraph] {
        var out: [Paragraph] = []
        var cur = Paragraph(text: [], label: nil)
        func flush() { if !cur.text.isEmpty { out.append(cur) }; cur = Paragraph(text: [], label: nil) }
        for raw in text.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { flush(); continue }
            let low = l.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]():."))
            let labels: [(String, SectionKind)] = [("chorus", .chorus), ("ritornello", .chorus), ("rit", .chorus), ("refrain", .chorus),
                                                   ("verse", .verse), ("strofa", .verse), ("bridge", .bridge), ("ponte", .bridge),
                                                   ("pre-chorus", .preChorus), ("prechorus", .preChorus), ("intro", .intro), ("outro", .outro), ("finale", .outro)]
            if l.count <= 18, let lab = labels.first(where: { low.hasPrefix($0.0) && low.count <= $0.0.count + 3 }) {
                flush(); cur.label = lab.1; continue
            }
            cur.text.append(l)
        }
        flush()
        return out
    }

    // MARK: Accordi

    private func assignChords(_ blocks: inout [Block], style: MusicStyle, key: Int, minor: Bool, ref: ReferenceTrack?, barSec: Double, rng: inout RNG) {
        // Gradi della scala (semitoni dalla tonica) e qualità.
        func deg(_ d: Int, _ q: Chord.Quality) -> Chord { Chord(root: key + d, quality: q) }
        let jazzy = [.jazz, .bossa, .soul, .lofi].contains(style)
        let majorProg: [[Chord]] = [
            [deg(0, .major), deg(7, .major), deg(9, .minor), deg(5, .major)],
            [deg(9, .minor), deg(5, .major), deg(0, .major), deg(7, .major)],
            [deg(0, .major), deg(9, .minor), deg(5, .major), deg(7, .major)],
            [deg(0, .major), deg(5, .major), deg(9, .minor), deg(7, .major)],
            [deg(5, .major), deg(0, .major), deg(7, .major), deg(9, .minor)],
            [deg(0, .major), deg(4, .minor), deg(5, .major), deg(7, .major)]
        ]
        let minorProg: [[Chord]] = [
            [deg(0, .minor), deg(8, .major), deg(3, .major), deg(10, .major)],
            [deg(0, .minor), deg(5, .minor), deg(10, .major), deg(3, .major)],
            [deg(0, .minor), deg(10, .major), deg(8, .major), deg(7, .major)],
            [deg(8, .major), deg(10, .major), deg(0, .minor), deg(0, .minor)],
            [deg(0, .minor), deg(5, .minor), deg(7, .major), deg(0, .minor)]
        ]
        let jazzProg: [[Chord]] = minor
            ? [[deg(2, .halfDim), deg(7, .seventh), deg(0, .minor7), deg(0, .minor7)], [deg(0, .minor7), deg(5, .minor7), deg(10, .seventh), deg(3, .major7)]]
            : [[deg(2, .minor7), deg(7, .seventh), deg(0, .major7), deg(9, .minor7)], [deg(0, .major7), deg(9, .minor7), deg(2, .minor7), deg(7, .seventh)],
               [deg(4, .minor7), deg(9, .seventh), deg(2, .minor7), deg(7, .seventh)]]
        let waltzProg: [[Chord]] = minor
            ? [[deg(0, .minor), deg(0, .minor), deg(7, .seventh), deg(7, .seventh), deg(7, .seventh), deg(7, .seventh), deg(0, .minor), deg(0, .minor)]]
            : [[deg(0, .major), deg(0, .major), deg(7, .seventh), deg(7, .seventh), deg(7, .seventh), deg(7, .seventh), deg(0, .major), deg(0, .major)],
               [deg(0, .major), deg(0, .major), deg(5, .major), deg(5, .major), deg(7, .seventh), deg(7, .seventh), deg(0, .major), deg(0, .major)]]
        var pool = jazzy ? jazzProg : (minor ? minorProg : majorProg)
        if style == .waltz || style == .liscio { pool = waltzProg }

        var verseP = rng.pick(pool)
        var chorusP = rng.pick(pool)
        var tries = 0
        while chorusP == verseP && pool.count > 1 && tries < 10 { chorusP = rng.pick(pool); tries += 1 }
        let bridgeP: [Chord] = minor ? [deg(5, .minor), deg(10, .major), deg(3, .major), deg(7, .major)]
                                     : [deg(5, .major), deg(7, .major), deg(4, .minor), deg(9, .minor)]
        if req.variety == 0 { chorusP = verseP }

        // "Stranezza": dominanti secondarie, prestiti dal modo minore, sospensioni, settime.
        func spice(_ p: [Chord]) -> [Chord] {
            let s = req.strangeness
            return p.enumerated().map { i, c in
                var c = c
                if rng.chance(s * 0.25) && !minor && c.root == (key + 9) % 12 { c = Chord(root: key + 4, quality: .seventh) }  // III7 → vi
                else if rng.chance(s * 0.2) && !minor && c.root == (key + 5) % 12 && i > 0 { c = Chord(root: key + 5, quality: .minor) } // iv prestito
                else if rng.chance(s * 0.15) && c.root == (key + 7) % 12 { c = Chord(root: c.root, quality: .sus4) }
                else if rng.chance(s * 0.12) && !minor && i == p.count - 1 { c = Chord(root: key + 10, quality: .major) }  // bVII
                if rng.chance(s * 0.35) && (c.quality == .major || c.quality == .minor) && !jazzy {
                    c = Chord(root: c.root, quality: c.quality == .major ? (c.root == (key + 7) % 12 ? .seventh : .add9) : .minor7)
                }
                return c
            }
        }
        verseP = spice(verseP); chorusP = spice(chorusP)

        var refBar = 0
        for i in blocks.indices {
            let b = blocks[i]
            var chords: [Chord] = []
            let base: [Chord]
            switch b.kind {
            case .chorus, .instrumental: base = chorusP
            case .bridge: base = spice(bridgeP)
            case .preChorus: base = [deg(5, minor ? .minor : .major), deg(7, .sus4), deg(5, minor ? .minor : .major), deg(7, .seventh)]
            case .intro, .outro: base = b.kind == .intro && style != .waltz && style != .liscio ? Array(chorusP.prefix(2)) + Array(chorusP.prefix(2)) : chorusP
            case .verse: base = verseP
            }
            // Ritmo armonico: ballate e valzer 1 accordo per battuta, cambi più veloci nel pop solo se le frasi sono corte.
            for k in 0..<b.bars {
                var c = base[k % base.count]
                if let r = ref, refBar + k < r.barChords.count, let rc = r.barChords[refBar + k] ?? r.barChords[..<min(r.barChords.count, refBar + k + 1)].last(where: { $0 != nil }) ?? nil {
                    if rng.next() < req.referenceWeight * 1.2 { c = rc }
                }
                if b.kind == .outro && k == b.bars - 1 { c = deg(0, minor ? .minor : (jazzy ? .major7 : .major)) }
                // Cadenza alla fine delle sezioni senza riferimento: V prima del ritornello.
                if ref == nil && k == b.bars - 1 && i + 1 < blocks.count && blocks[i + 1].kind == .chorus && b.kind != .intro {
                    c = deg(7, rng.chance(0.5) ? .seventh : .sus4)
                }
                chords.append(c)
            }
            blocks[i].chords = chords
            refBar += b.bars
        }
    }

    // MARK: Strumenti

    struct Part { var name: String; var inst: Instrument; var ch: UInt8; var program: UInt8; var volume: UInt8; var pan: UInt8; var reverb: UInt8 }

    private func instrumentation(_ s: MusicStyle) -> [Part] {
        func p(_ n: String, _ i: Instrument, _ ch: UInt8, _ prog: UInt8, _ vol: UInt8 = 100, _ pan: UInt8 = 64, _ rev: UInt8 = 40) -> Part {
            Part(name: n, inst: i, ch: ch, program: prog, volume: vol, pan: pan, reverb: rev)
        }
        var parts: [Part] = [p("Batteria", .drums, 9, s == .jazz || s == .bossa ? 32 : (s == .dance || s == .house ? 25 : 0), 105, 64, 30)]
        switch s {
        case .pop: parts += [p("Basso", .bass, 1, 33, 100), p("Piano", .piano, 2, 0, 92, 54), p("Chitarra", .guitar, 3, 25, 78, 80), p("Archi", .strings, 4, 48, 72, 64, 70), p("Pad", .pad, 5, 89, 60, 64, 70)]
        case .rock: parts += [p("Basso", .bass, 1, 34, 105), p("Chitarra ritmica", .guitar, 3, 29, 92, 40), p("Organo", .piano, 2, 17, 70, 88), p("Pad", .pad, 5, 89, 50)]
        case .pianoBallad: parts += [p("Pianoforte", .piano, 2, 0, 110, 64, 60), p("Basso", .bass, 1, 32, 85), p("Archi", .strings, 4, 49, 80, 64, 80), p("Pad", .pad, 5, 89, 50, 64, 80)]
        case .acoustic, .country: parts += [p("Chitarra acustica", .guitar, 3, 25, 100, 50), p("Basso", .bass, 1, 32, 95), p("Piano", .piano, 2, 0, 70, 80), p("Archi", .strings, 4, 48, 60, 64, 60)]
        case .dance, .house: parts += [p("Basso synth", .bass, 1, 38, 105), p("Accordi synth", .piano, 2, 81, 75, 64, 50), p("Pad", .pad, 5, 90, 72, 64, 70), p("Archi", .strings, 4, 50, 55)]
        case .lofi: parts += [p("Rhodes", .piano, 2, 4, 95, 60, 60), p("Basso", .bass, 1, 33, 95), p("Pad", .pad, 5, 88, 55, 64, 70), p("Chitarra", .guitar, 3, 26, 55, 84)]
        case .jazz: parts += [p("Contrabbasso", .bass, 1, 32, 100), p("Piano jazz", .piano, 2, 0, 95, 70), p("Fiati", .brass, 6, 66, 70, 50), p("Chitarra jazz", .guitar, 3, 26, 60, 40)]
        case .bossa: parts += [p("Chitarra nylon", .guitar, 3, 24, 100, 54), p("Contrabbasso", .bass, 1, 32, 95), p("Rhodes", .piano, 2, 4, 65, 80), p("Archi", .strings, 4, 48, 50, 64, 70)]
        case .latin, .reggaeton: parts += [p("Basso", .bass, 1, s == .reggaeton ? 38 : 33, 105), p("Piano", .piano, 2, 0, 88, 60), p("Fiati", .brass, 6, 61, 80, 70), p("Pad", .pad, 5, 89, 55)]
        case .soul: parts += [p("Basso", .bass, 1, 33, 100), p("Rhodes", .piano, 2, 4, 92, 56), p("Organo", .pad, 5, 16, 55, 76), p("Fiati", .brass, 6, 61, 70, 64), p("Chitarra", .guitar, 3, 27, 60, 90)]
        case .cinematic: parts += [p("Archi", .strings, 4, 48, 105, 64, 90), p("Pianoforte", .piano, 2, 0, 90, 64, 80), p("Contrabbassi", .bass, 1, 43, 90, 64, 80), p("Pad", .pad, 5, 91, 70, 64, 90), p("Ottoni", .brass, 6, 60, 70, 64, 80)]
        case .waltz, .liscio: parts += [p("Basso", .bass, 1, 32, 95), p("Fisarmonica", .piano, 2, s == .liscio ? 21 : 0, 92, 70), p("Chitarra", .guitar, 3, 25, 70, 44), p("Archi", .strings, 4, 48, 55, 64, 60)]
        }
        if req.vocal == .guideMelody {
            let leadProg: UInt8 = s == .jazz || s == .soul ? 65 : (s == .liscio ? 21 : (s == .dance || s == .house ? 81 : 73))
            parts.append(p("Melodia guida", .lead, 7, leadProg, 100, 64, 50))
        }
        return parts
    }

    private func addNote(_ evs: inout [MIDIWriter.TrackEvent], _ ch: UInt8, _ pitch: Int, _ t: Int, _ dur: Int, _ vel: UInt8) {
        let p = UInt8(pitch.clamped(0, 127))
        let v = UInt8(Int(vel).clamped(1, 127))
        evs.append(.init(tick: max(0, t), bytes: [0x90 | ch, p, v]))
        evs.append(.init(tick: max(0, t) + max(10, dur), bytes: [0x80 | ch, p, 0]))
    }

    // MARK: Batteria (GM: 36 cassa, 38 rullante, 37 rim, 42 hh chiuso, 46 hh aperto, 49 crash, 51 ride, 39 clap)

    private func drums(_ evs: inout [MIDIWriter.TrackEvent], style: MusicStyle, t0: Int, bpb: Int, intensity: Double,
                       fill: Bool, crash: Bool, final: Bool, kind: SectionKind, sw: (Int) -> Int, rng: inout RNG) {
        let s16 = SongGenerator.ppq / 4
        let steps = bpb * 4
        // Pattern a 16esimi: "x" = colpo forte, "o" = colpo leggero.
        var kick = "", snare = "", hat = "", hat2 = ""
        switch style {
        case .pop, .acoustic, .country:
            kick = "x.....x.x.......";   snare = "....x.......x..."; hat = "x.o.x.o.x.o.x.o."
        case .rock:
            kick = "x.....x.x.x.....";   snare = "....x.......x..."; hat = "x.x.x.x.x.x.x.x."
        case .pianoBallad, .cinematic:
            kick = "x.........x.....";   snare = "........x......."; hat = "x...o...x...o..."
        case .dance, .house:
            kick = "x...x...x...x...";   snare = "....x.......x..."; hat = "..x...x...x...x."; hat2 = "o.o.o.o.o.o.o.o."
        case .lofi, .soul:
            kick = "x......x..x.....";   snare = "....x.......x..."; hat = "x.o.x.o.x.o.x.oo"
        case .jazz:
            kick = "x...............";   snare = "..........o....."; hat = "x...x..ox...x..o"
        case .bossa:
            kick = "x..xx..xx..xx..x";   snare = "o..o..o...o..o.."; hat = "x.x.x.x.x.x.x.x."
        case .latin:
            kick = "x..x..x.x..x..x.";   snare = "...o..x....o..x."; hat = "x.xxx.xxx.xxx.xx"
        case .reggaeton:
            kick = "x...x...x...x...";   snare = "...x..x....x..x."; hat = "x.x.x.x.x.x.x.x."
        case .waltz, .liscio:
            kick = "x...........";       snare = "....x...x..."; hat = "x...x...x..."
        }
        func play(_ pat: String, _ note: Int, _ base: Double) {
            for (i, c) in pat.enumerated() where i < steps && c != "." {
                let v = (c == "x" ? base : base * 0.65) * (0.7 + 0.3 * intensity) + Double(rng.int(-6, 6))
                addNote(&evs, 9, note, sw(t0 + i * s16), s16, UInt8(v.clamped(1, 127)))
            }
        }
        if final {
            addNote(&evs, 9, 36, t0, s16, 110); addNote(&evs, 9, 49, t0, s16 * 8, 110)
            return
        }
        if kind == .intro && intensity < 0.6 && style != .dance && style != .house {
            // Intro leggera: solo hi-hat/ride.
            play(hat, style == .jazz ? 51 : 42, 70)
        } else if fill && (style != .jazz) {
            let half = steps / 2
            play(String(kick.prefix(half)), 36, 100)
            play(String(snare.prefix(half)), 38, 96)
            play(String(hat.prefix(half)), 42, 80)
            // Rullata: rullante e tom in 16esimi crescenti.
            let toms = [38, 38, 50, 50, 47, 47, 45, 41]
            for k in 0..<(steps - half) {
                addNote(&evs, 9, toms[min(toms.count - 1, k * toms.count / max(1, steps - half))], t0 + (half + k) * s16, s16, UInt8(70 + k * 5))
            }
        } else {
            play(kick, 36, 108)
            play(snare, kind == .verse && style != .rock && style != .dance ? 37 : 38, kind == .verse ? 88 : 100)
            play(hat, kind == .chorus && (style == .rock || style == .pop) ? 46 : (style == .jazz ? 51 : 42), 82)
            if !hat2.isEmpty { play(hat2, 46, 60) }
            if kind == .chorus && (style == .pop || style == .dance || style == .house) { play("....x.......x...", 39, 70) }
        }
        if crash && intensity >= 0.7 { addNote(&evs, 9, 49, t0, s16 * 4, 100) }
    }

    // MARK: Basso

    private func bassLine(_ evs: inout [MIDIWriter.TrackEvent], ch: UInt8, style: MusicStyle, chord: Chord, next: Chord,
                          t0: Int, bpb: Int, intensity: Double, final: Bool, sw: (Int) -> Int, rng: inout RNG) {
        let q = SongGenerator.ppq, e = q / 2
        var root = 28 + ((chord.bass ?? chord.root) + 12 - 4) % 12   // tra Mi1 e Re#2
        if root < 28 { root += 12 }
        let fifth = root + 7 > 47 ? root - 5 : root + 7
        let third = root + (chord.quality.isMinor ? 3 : 4)
        let oct = root + 12
        let vel = UInt8(85 + 20 * intensity)
        if final { addNote(&evs, ch, root, t0, q * bpb * 2, vel); return }
        switch style {
        case .rock:
            for i in 0..<(bpb * 2) { addNote(&evs, ch, root, t0 + i * e, e - 30, vel - (i % 2 == 0 ? 0 : 12)) }
        case .dance, .house:
            for i in 0..<(bpb * 2) { addNote(&evs, ch, i % 2 == 0 ? root : oct, t0 + i * e, e - 40, vel) }
        case .jazz:
            // Walking bass verso l'accordo successivo.
            let target = 28 + (next.root + 12 - 4) % 12
            let walk = [root, third, fifth, target > fifth ? target - 1 : target + 1]
            for i in 0..<bpb { addNote(&evs, ch, walk[i % walk.count], sw(t0 + i * q), q - 30, vel - UInt8(i * 3)) }
        case .bossa:
            addNote(&evs, ch, root, t0, q + e - 20, vel); addNote(&evs, ch, fifth, t0 + q + e, e - 20, vel - 10)
            addNote(&evs, ch, fifth, t0 + 2 * q, q + e - 20, vel - 5); addNote(&evs, ch, root, t0 + 3 * q + e, e - 20, vel - 10)
        case .latin:
            addNote(&evs, ch, root, t0 + q + e, q - 20, vel); addNote(&evs, ch, fifth, t0 + 3 * q, q - 20, vel)
        case .reggaeton:
            addNote(&evs, ch, root, t0, q + e - 20, vel); addNote(&evs, ch, root, t0 + q + e, e - 20, vel - 10)
            addNote(&evs, ch, root, t0 + 2 * q, q - 20, vel); addNote(&evs, ch, fifth, t0 + 3 * q, q - 20, vel - 10)
        case .waltz, .liscio:
            addNote(&evs, ch, rng.chance(0.5) ? root : fifth, t0, q - 20, vel)
            if style == .liscio { addNote(&evs, ch, fifth, t0 + 2 * q + e, e - 20, vel - 25) }
        case .pianoBallad, .cinematic:
            addNote(&evs, ch, root, t0, q * bpb - 20, vel - 10)
        case .lofi, .soul:
            addNote(&evs, ch, root, t0, q + e - 20, vel); addNote(&evs, ch, oct, sw(t0 + q + e), e - 20, vel - 20)
            addNote(&evs, ch, fifth, t0 + 2 * q + e, e - 20, vel - 10); addNote(&evs, ch, root, sw(t0 + 3 * q + e), e - 20, vel - 15)
        case .pop, .acoustic, .country:
            if intensity >= 0.9 {
                for i in 0..<(bpb * 2) { addNote(&evs, ch, i == 5 ? fifth : root, t0 + i * e, e - 30, vel - (i % 2 == 0 ? 0 : 15)) }
            } else {
                addNote(&evs, ch, root, t0, q * 2 - e - 20, vel); addNote(&evs, ch, root, t0 + q + e, e - 20, vel - 15)
                addNote(&evs, ch, fifth, t0 + 2 * q, q * 2 - 20, vel - 5)
            }
        }
    }

    // MARK: Accompagnamento (piano, chitarra, tastiere)

    private func comp(_ evs: inout [MIDIWriter.TrackEvent], part: Part, style: MusicStyle, voicing v: [Int], chord: Chord,
                      t0: Int, bpb: Int, intensity: Double, kind: SectionKind, final: Bool, sw: (Int) -> Int, rng: inout RNG) {
        let q = SongGenerator.ppq, e = q / 2
        let ch = part.ch
        let base = Double(part.inst == .guitar ? 78 : 80) * (0.75 + 0.3 * intensity)
        func hit(_ t: Int, _ dur: Int, _ vScale: Double = 1, strum: Bool = false, down: Bool = true) {
            let notes = down ? v : v.reversed()
            for (i, n) in notes.enumerated() {
                addNote(&evs, ch, n, t + (strum ? i * 12 : i * 2), dur, UInt8((base * vScale + Double(rng.int(-5, 5))).clamped(1, 127)))
            }
        }
        if final { hit(t0, q * bpb * 2, 1, strum: true); return }
        let isPiano = part.inst == .piano
        // Pedale per il pianoforte.
        if isPiano && [MusicStyle.pianoBallad, .cinematic, .pop, .acoustic].contains(style) {
            evs.append(.init(tick: max(0, t0 - 2), bytes: [0xB0 | ch, 64, 0]))
            evs.append(.init(tick: t0 + 20, bytes: [0xB0 | ch, 64, 115]))
        }
        switch style {
        case .pianoBallad, .cinematic:
            if isPiano {
                // Arpeggio a crome con basso della mano sinistra.
                let lh = 36 + (chord.root + 12 - 0) % 12
                addNote(&evs, ch, lh < 41 ? lh + 12 : lh, t0, q * bpb, UInt8(base))
                let pat = [0, 1, 2, 1, 2, 1, 2, 1]
                for i in 0..<(bpb * 2) where !v.isEmpty { addNote(&evs, ch, v[pat[i % pat.count] % v.count], t0 + i * e, e * 2, UInt8(base * (i % 2 == 0 ? 0.85 : 0.7))) }
            } else { hit(t0, q * bpb, 0.8) }
        case .rock:
            if part.inst == .guitar { for i in 0..<(bpb * 2) { hit(t0 + i * e, e - 20, i % 2 == 0 ? 1 : 0.8, strum: true, down: i % 2 == 0) } }
            else { hit(t0, q * bpb - 20, 0.7) }
        case .dance, .house:
            // Accordi in levare (off-beat).
            for i in 0..<bpb { hit(t0 + i * q + e, e - 30, 0.9) }
        case .jazz:
            // Comping charleston.
            hit(sw(t0), q + e - 40, 0.85); hit(sw(t0 + q + e), e, 0.75)
            if rng.chance(0.5) { hit(sw(t0 + 3 * q + e), e, 0.7) }
        case .bossa:
            let pat = [0, 3, 6, 10, 13]
            for p in pat { hit(t0 + p * (q / 4), q / 2, 0.8) }
        case .latin:
            // Montuno.
            for i in 0..<(bpb * 2) where i != 3 && i != 7 { if !v.isEmpty { addNote(&evs, ch, v[i % v.count] + (i % 2 == 0 ? 0 : 12), t0 + i * e, e - 20, UInt8(base * 0.85)) } }
        case .reggaeton:
            hit(t0 + q + e, e, 0.8); hit(t0 + 3 * q + e, e, 0.8)
        case .waltz, .liscio:
            hit(t0 + q, q - 40, 0.75); hit(t0 + 2 * q, q - 40, 0.75)
        case .lofi, .soul:
            hit(sw(t0), q * 2 - 30, 0.8); hit(sw(t0 + 2 * q + e), q + e - 30, 0.7)
        case .pop, .acoustic, .country:
            if part.inst == .guitar {
                // Pennata: giù, giù-su, su-giù-su.
                let pattern: [(Int, Bool)] = [(0, true), (2, true), (3, false), (5, false), (6, true), (7, false)]
                for (s, d) in pattern where s < bpb * 2 { hit(t0 + s * e, e * 2 - 20, d ? 0.9 : 0.7, strum: true, down: d) }
            } else if kind == .verse || kind == .intro {
                hit(t0, q * 2 - 20, 0.8); hit(t0 + 2 * q, q * 2 - 20, 0.7)
            } else {
                // 3+3+2.
                hit(t0, q + e - 20, 0.95); hit(t0 + q + e, q + e - 20, 0.85); hit(t0 + 3 * q, q - 20, 0.85)
            }
        }
    }

    // MARK: Melodia guida

    private struct MelNote { var tick: Int; var dur: Int; var pitch: Int }

    private func melodyFor(syllables: [Syllabifier.Syllable], chords: [Chord], startTick: Int, bpb: Int,
                           key: Int, minor: Bool, kind: SectionKind, lineIndex: Int, rng: inout RNG) -> [MelNote] {
        guard !syllables.isEmpty else { return [] }
        let q = SongGenerator.ppq, e = q / 2
        let barT = q * bpb
        let totalBars = max(1, chords.count)
        let scale = minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        // Registro: ritornello più alto.
        let center = 64 + (kind == .chorus ? 5 : 0) + (kind == .bridge ? 3 : 0)
        // Posizioni ritmiche: la frase occupa ~80% delle battute, partenza sul levare del 1.
        let slots = totalBars * bpb * 2
        let usable = max(syllables.count, Int(Double(slots) * 0.8))
        let startSlot = kind == .chorus ? 0 : 1
        var times: [Int] = []
        let stride = Double(min(usable, slots - startSlot)) / Double(syllables.count)
        for i in 0..<syllables.count {
            let s = startSlot + Int((Double(i) * stride).rounded(.down))
            times.append(min(slots - 1, s))
        }
        // Accenti: le sillabe toniche vanno sui tempi forti quando possibile.
        for i in 0..<times.count where syllables[i].stressed && times[i] % 2 == 1 && (i + 1 >= times.count || times[i] + 1 < times[i + 1]) {
            times[i] += 1
        }
        var out: [MelNote] = []
        var prevPitch = center
        let contourPeak = Double(syllables.count) * (0.55 + rng.next() * 0.2)
        for (i, slot) in times.enumerated() {
            let tick = startTick + slot * e
            let barIdx = min(chords.count - 1, slot / (bpb * 2))
            let c = chords[barIdx]
            let strong = slot % 2 == 0
            let arch = 1 - abs(Double(i) - contourPeak) / max(1, contourPeak)
            let target = Double(center) + arch * 4 - 2
            var candidates: [Int] = []
            for p in (center - 9)...(center + 10) {
                let pc = ((p - key) % 12 + 12) % 12
                if strong { if c.pitchClasses.contains(((p % 12) + 12) % 12) { candidates.append(p) } }
                else if scale.contains(pc) { candidates.append(p) }
            }
            if candidates.isEmpty { candidates = [prevPitch] }
            let best = candidates.min { a, b in
                let ca = Double(abs(a - prevPitch)) * 0.9 + abs(Double(a) - target) * 0.6 + (a == prevPitch ? 0.8 : 0)
                let cb = Double(abs(b - prevPitch)) * 0.9 + abs(Double(b) - target) * 0.6 + (b == prevPitch ? 0.8 : 0)
                return ca < cb
            }!
            // Fine frase: nota dell'accordo, durata lunga.
            let isLast = i == times.count - 1
            let nextTick = isLast ? startTick + totalBars * barT - e : startTick + times[i + 1] * e
            var pitch = best
            if isLast {
                pitch = c.pitchClasses.map { pc -> Int in var p = center - 6; while ((p % 12) + 12) % 12 != pc { p += 1 }; return p }
                    .min { abs($0 - prevPitch) < abs($1 - prevPitch) } ?? best
            }
            out.append(MelNote(tick: tick, dur: max(e / 2, min(nextTick - tick - 20, isLast ? barT : q * 2)), pitch: pitch))
            prevPitch = pitch
        }
        return out
    }
}

extension MIDIFile {
    static func lyricEventsFromTicks(_ lyrics: KaraokeLyrics, secondsPerTick: Double) -> [MIDIWriter.TrackEvent] {
        var out: [MIDIWriter.TrackEvent] = []
        for l in lyrics.lines {
            for (si, s) in l.syllables.enumerated() where s.time >= 0 {
                var txt = s.text
                if si == l.syllables.count - 1 { txt += l.endsParagraph ? "\r\n" : "\r" }
                out.append(.init(tick: Int((s.time / secondsPerTick).rounded()), bytes: MIDIWriter.text(0x05, txt)))
            }
        }
        return out
    }
}

/// Sillabazione italiana semplificata (sufficiente per karaoke e melodia).
enum Syllabifier {
    struct Syllable { var text: String; var stressed: Bool }

    static func syllables(_ line: String) -> [Syllable] {
        var out: [Syllable] = []
        let words = line.split(separator: " ").map(String.init)
        for (wi, w) in words.enumerated() {
            let parts = split(w)
            for (pi, p) in parts.enumerated() {
                let last = pi == parts.count - 1
                // Accento: penultima sillaba (parola piana), oppure vocale accentata.
                let accented = p.contains { "àèéìòù".contains($0) }
                let stressed = accented || (parts.count >= 2 && pi == parts.count - 2 && !parts.joined().contains { "àèéìòù".contains($0) }) || parts.count == 1
                out.append(Syllable(text: p + (last && wi < words.count - 1 ? " " : ""), stressed: stressed))
            }
        }
        return out
    }

    static func split(_ word: String) -> [String] {
        let chars = Array(word)
        func isV(_ c: Character) -> Bool { "aeiouàèéìòùyAEIOUÀÈÉÌÒÙY".contains(c) }
        guard chars.count > 3, chars.contains(where: isV) else { return [word] }
        var out: [String] = []
        var cur = ""
        var i = 0
        while i < chars.count {
            cur.append(chars[i])
            if isV(chars[i]) {
                // Conta le consonanti che seguono.
                var j = i + 1
                while j < chars.count && !isV(chars[j]) && chars[j].isLetter { j += 1 }
                let cons = j - (i + 1)
                if j >= chars.count { cur += String(chars[(i + 1)...]); i = chars.count; break }
                if cons == 0 {
                    // Iato semplice: tengo i dittonghi con i/u.
                    if "iuIU".contains(chars[i]) || "iuIU".contains(chars[i + 1]) { i += 1; continue }
                    out.append(cur); cur = ""
                } else if cons == 1 {
                    out.append(cur); cur = ""
                } else {
                    let c1 = chars[i + 1], c2 = chars[i + 2]
                    let lowered = String([c1, c2]).lowercased()
                    let inseparable = ["ch", "gh", "gn", "gl", "sc", "qu"].contains(lowered) ||
                        ("bcdfgptv".contains(Character(c1.lowercased())) && "lr".contains(Character(c2.lowercased())))
                    if c1.lowercased() == "s" || inseparable {
                        out.append(cur); cur = ""
                    } else {
                        cur.append(c1); out.append(cur); cur = ""; i += 1
                    }
                }
            }
            i += 1
        }
        if !cur.isEmpty {
            if cur.contains(where: isV) || out.isEmpty { out.append(cur) } else { out[out.count - 1] += cur }
        }
        return out
    }
}
