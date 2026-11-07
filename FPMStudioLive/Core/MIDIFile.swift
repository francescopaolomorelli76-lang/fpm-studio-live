import Foundation

/// Un evento MIDI con tempo assoluto in tick.
struct MIDIEvent {
    enum Kind {
        case channel(status: UInt8, d1: UInt8, d2: UInt8)
        case meta(type: UInt8, data: [UInt8])
        case sysex(data: [UInt8])
    }
    var tick: Int
    var track: Int
    var kind: Kind

    var channel: Int? {
        if case .channel(let s, _, _) = kind { return Int(s & 0x0F) }
        return nil
    }
    var command: UInt8? {
        if case .channel(let s, _, _) = kind { return s & 0xF0 }
        return nil
    }
}

struct MIDINote {
    var channel: Int
    var pitch: Int
    var velocity: Int
    var startTick: Int
    var endTick: Int
    var track: Int
}

enum MIDIError: LocalizedError {
    case notMIDI, truncated, unsupported(String)
    var errorDescription: String? {
        switch self {
        case .notMIDI: return "Il file non è un MIDI valido."
        case .truncated: return "Il file MIDI è troncato o danneggiato."
        case .unsupported(let s): return "MIDI non supportato: \(s)"
        }
    }
}

/// File MIDI standard (tipo 0/1) letto in memoria, con mappa dei tempi, testi karaoke e note.
final class MIDIFile {
    private(set) var format: Int = 1
    private(set) var ppq: Int = 480
    private(set) var events: [MIDIEvent] = []          // ordinati per tick
    private(set) var notes: [MIDINote] = []
    private(set) var trackNames: [Int: String] = [:]
    private(set) var tempoMap: [(tick: Int, usPerQuarter: Int)] = [(0, 500_000)]
    private(set) var timeSignatures: [(tick: Int, num: Int, den: Int)] = []
    private(set) var programs: [Int: Int] = [:]       // canale -> primo programma
    private(set) var endTick: Int = 0
    private(set) var title: String?
    private var secondsAtTempo: [Double] = [0]

    init(data: Data) throws {
        try parse([UInt8](data))
        buildDerived()
    }

    convenience init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }

    // MARK: - Parsing

    private func parse(_ b: [UInt8]) throws {
        var p = 0
        // Alcuni file RIFF-MIDI (.rmi) incapsulano lo SMF.
        if b.count > 20, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46 {
            if let r = findSubsequence(b, [0x4D, 0x54, 0x68, 0x64]) { p = r } else { throw MIDIError.notMIDI }
        }
        func u32(_ i: Int) throws -> Int {
            guard i + 4 <= b.count else { throw MIDIError.truncated }
            return Int(b[i]) << 24 | Int(b[i+1]) << 16 | Int(b[i+2]) << 8 | Int(b[i+3])
        }
        func u16(_ i: Int) throws -> Int {
            guard i + 2 <= b.count else { throw MIDIError.truncated }
            return Int(b[i]) << 8 | Int(b[i+1])
        }
        guard b.count >= p + 14, b[p] == 0x4D, b[p+1] == 0x54, b[p+2] == 0x68, b[p+3] == 0x64 else { throw MIDIError.notMIDI }
        let hlen = try u32(p + 4)
        format = try u16(p + 8)
        let ntrk = try u16(p + 10)
        let division = try u16(p + 12)
        if division & 0x8000 != 0 {
            // SMPTE: converto in un PPQ equivalente a 120 BPM.
            let fps = 256 - (division >> 8)
            let tpf = division & 0xFF
            ppq = max(24, fps * tpf / 2)
        } else {
            ppq = max(1, division)
        }
        p += 8 + hlen
        var all: [MIDIEvent] = []
        var trackIndex = 0
        while trackIndex < ntrk && p + 8 <= b.count {
            let isTrack = b[p] == 0x4D && b[p+1] == 0x54 && b[p+2] == 0x72 && b[p+3] == 0x6B
            let len = try u32(p + 4)
            p += 8
            let end = min(b.count, p + len)
            if !isTrack { p = end; continue }
            var tick = 0
            var running: UInt8 = 0
            var q = p
            func vl() throws -> Int {
                var n = 0
                for _ in 0..<4 {
                    guard q < end else { throw MIDIError.truncated }
                    let x = b[q]; q += 1
                    n = (n << 7) | Int(x & 0x7F)
                    if x & 0x80 == 0 { return n }
                }
                return n
            }
            parseLoop: while q < end {
                guard let delta = try? vl() else { break }
                tick += delta
                guard q < end else { break }
                var status = b[q]
                if status & 0x80 != 0 { q += 1 } else {
                    guard running != 0 else { break parseLoop }
                    status = running
                }
                switch status {
                case 0xFF:
                    guard q < end else { break parseLoop }
                    let type = b[q]; q += 1
                    guard let l = try? vl(), q + l <= end else { break parseLoop }
                    let data = Array(b[q..<q+l]); q += l
                    all.append(MIDIEvent(tick: tick, track: trackIndex, kind: .meta(type: type, data: data)))
                    if type == 0x2F { break parseLoop }
                case 0xF0, 0xF7:
                    guard let l = try? vl(), q + l <= end else { break parseLoop }
                    let data = Array(b[q..<q+l]); q += l
                    all.append(MIDIEvent(tick: tick, track: trackIndex, kind: .sysex(data: data)))
                    running = 0
                default:
                    running = status
                    let cmd = status & 0xF0
                    let needs2 = !(cmd == 0xC0 || cmd == 0xD0)
                    guard q < end else { break parseLoop }
                    let d1 = b[q]; q += 1
                    var d2: UInt8 = 0
                    if needs2 { guard q < end else { break parseLoop }; d2 = b[q]; q += 1 }
                    all.append(MIDIEvent(tick: tick, track: trackIndex, kind: .channel(status: status, d1: d1 & 0x7F, d2: d2 & 0x7F)))
                }
            }
            p = end
            trackIndex += 1
        }
        if all.isEmpty { throw MIDIError.truncated }
        // Ordinamento stabile per tick.
        events = all.enumerated().sorted { a, c in
            a.element.tick != c.element.tick ? a.element.tick < c.element.tick : a.offset < c.offset
        }.map { $0.element }
    }

    private func findSubsequence(_ b: [UInt8], _ s: [UInt8]) -> Int? {
        guard b.count >= s.count else { return nil }
        for i in 0...(b.count - s.count) where b[i] == s[0] {
            if Array(b[i..<i+s.count]) == s { return i }
        }
        return nil
    }

    private func buildDerived() {
        var tempos: [(Int, Int)] = []
        var open: [Int: [(Int, Int)]] = [:] // key ch*128+pitch -> [(tick, vel)]
        var ns: [MIDINote] = []
        for e in events {
            endTick = max(endTick, e.tick)
            switch e.kind {
            case .meta(let type, let data):
                if type == 0x51, data.count >= 3 {
                    tempos.append((e.tick, Int(data[0]) << 16 | Int(data[1]) << 8 | Int(data[2])))
                } else if type == 0x58, data.count >= 2 {
                    timeSignatures.append((e.tick, Int(data[0]), 1 << Int(min(data[1], 6))))
                } else if type == 0x03, trackNames[e.track] == nil {
                    trackNames[e.track] = TextDecoding.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .channel(let s, let d1, let d2):
                let ch = Int(s & 0x0F), cmd = s & 0xF0
                if cmd == 0xC0, programs[ch] == nil { programs[ch] = Int(d1) }
                if cmd == 0x90 && d2 > 0 {
                    open[ch * 128 + Int(d1), default: []].append((e.tick, Int(d2)))
                } else if cmd == 0x80 || (cmd == 0x90 && d2 == 0) {
                    let k = ch * 128 + Int(d1)
                    if var st = open[k], !st.isEmpty {
                        let (t0, v) = st.removeFirst()
                        open[k] = st
                        ns.append(MIDINote(channel: ch, pitch: Int(d1), velocity: v, startTick: t0, endTick: max(t0 + 1, e.tick), track: e.track))
                    }
                }
            case .sysex: break
            }
        }
        for (k, st) in open {
            for (t0, v) in st {
                ns.append(MIDINote(channel: k / 128, pitch: k % 128, velocity: v, startTick: t0, endTick: max(t0 + ppq / 2, endTick), track: 0))
            }
        }
        notes = ns.sorted { $0.startTick < $1.startTick }
        if !tempos.isEmpty {
            tempos.sort { $0.0 < $1.0 }
            if tempos[0].0 != 0 { tempos.insert((0, 500_000), at: 0) }
            tempoMap = tempos.map { (tick: $0.0, usPerQuarter: max(1, $0.1)) }
        }
        secondsAtTempo = [0]
        for i in 1..<max(1, tempoMap.count) {
            let prev = tempoMap[i-1]
            let dt = Double(tempoMap[i].tick - prev.tick) * Double(prev.usPerQuarter) / 1_000_000 / Double(ppq)
            secondsAtTempo.append(secondsAtTempo[i-1] + dt)
        }
        if let t = trackNames[0], !t.isEmpty, format == 1 { title = t }
    }

    // MARK: - Tempo

    func seconds(atTick tick: Int) -> Double {
        var i = tempoMap.count - 1
        while i > 0 && tempoMap[i].tick > tick { i -= 1 }
        let t = tempoMap[i]
        return secondsAtTempo[i] + Double(tick - t.tick) * Double(t.usPerQuarter) / 1_000_000 / Double(ppq)
    }

    func tick(atSeconds s: Double) -> Int {
        var i = tempoMap.count - 1
        while i > 0 && secondsAtTempo[i] > s { i -= 1 }
        let t = tempoMap[i]
        return t.tick + Int((s - secondsAtTempo[i]) * 1_000_000 / Double(t.usPerQuarter) * Double(ppq))
    }

    var duration: Double { seconds(atTick: endTick) }

    /// BPM prevalente (pesato sulla durata).
    var mainBPM: Double {
        var span: [Int: Int] = [:]
        for (i, t) in tempoMap.enumerated() {
            let to = i + 1 < tempoMap.count ? tempoMap[i+1].tick : endTick
            span[Int((60_000_000.0 / Double(t.usPerQuarter)).rounded()), default: 0] += max(0, to - t.tick)
        }
        return Double(span.max { $0.value < $1.value }?.key ?? 120)
    }

    /// Metrica prevalente.
    var mainTimeSignature: (num: Int, den: Int) {
        guard !timeSignatures.isEmpty else { return (4, 4) }
        var span: [String: Int] = [:]
        for (i, t) in timeSignatures.enumerated() {
            let to = i + 1 < timeSignatures.count ? timeSignatures[i+1].tick : endTick
            span["\(t.num)/\(t.den)", default: 0] += max(1, to - t.tick)
        }
        let best = span.max { $0.value < $1.value }!.key.split(separator: "/")
        return (Int(best[0]) ?? 4, Int(best[1]) ?? 4)
    }

    var ticksPerBeat: Int { max(1, ppq * 4 / mainTimeSignature.den) }
    var ticksPerBar: Int { ticksPerBeat * mainTimeSignature.num }

    var usedChannels: [Int] { Array(Set(notes.map { $0.channel })).sorted() }

    // MARK: - Testi karaoke

    /// Estrae i testi da eventi Lyric (FF05) o Text (FF01, formato .kar).
    /// Sceglie automaticamente la traccia con più sillabe (ignora titoli, copyright e note varie)
    /// e riconosce gli a capo in tutte le forme usate: "/", "\\", "\r", "\n" all'inizio o alla fine.
    func karaokeLyrics() -> KaraokeLyrics {
        var groups: [String: [(Int, String)]] = [:]
        var karHeaders: [String] = []
        for e in events {
            guard case .meta(let type, let data) = e.kind, type == 0x01 || type == 0x05 else { continue }
            let s = TextDecoding.decode(data)
            if type == 0x01 && s.hasPrefix("@") { karHeaders.append(s); continue }
            groups["\(type)-\(e.track)", default: []].append((e.tick, s))
        }
        var lyrics = KaraokeLyrics()
        for h in karHeaders where h.hasPrefix("@T") {
            let v = String(h.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if lyrics.title == nil { lyrics.title = v } else if lyrics.artist == nil { lyrics.artist = v }
        }
        // Punteggio: numero di eventi in istanti diversi (dopo l'inizio), preferendo i Lyric (FF05) a parità.
        func score(_ k: String, _ g: [(Int, String)]) -> Double {
            let distinct = Set(g.filter { $0.0 > 0 }.map { $0.0 }).count
            let breaks = g.filter { $0.1.hasPrefix("/") || $0.1.hasPrefix("\\") || $0.1.unicodeScalars.contains { $0 == "\r" || $0 == "\n" } }.count
            return Double(distinct) + Double(min(breaks, 20)) * 0.5 + (k.hasPrefix("5-") ? 2 : 0)
        }
        guard let best = groups.max(by: { score($0.key, $0.value) < score($1.key, $1.value) }), best.value.count >= 3 else {
            // Basi M-Live (le originali di Win Live): testo e accordi nei SysEx M-Live.
            let ml = mLiveLyrics()
            return ml.isEmpty ? lyrics : ml
        }
        let source = best.value   // già in ordine di tempo (ordinamento stabile del parser)

        var line = LyricLine()
        func flush(paragraph: Bool) {
            if !line.syllables.isEmpty { lyrics.lines.append(line) }
            line = LyricLine()
            if paragraph, !lyrics.lines.isEmpty { lyrics.lines[lyrics.lines.count - 1].endsParagraph = true }
        }
        var hadBreaks = false
        // Simbolo di inizio riga usato da alcuni produttori (es. "<IO MI NASCOSI…"): se la maggior parte
        // degli eventi comincia con lo stesso segno, quel segno vale come "a capo".
        let markers: Set<Character> = ["<", ">", "#", "%", "^", "~", "|", "*"]
        var markerCount: [Character: Int] = [:]
        for (_, raw) in source { if let f = raw.first, markers.contains(f) { markerCount[f, default: 0] += 1 } }
        let lineMarker = markerCount.max { $0.value < $1.value }.flatMap { Double($0.value) >= Double(source.count) * 0.4 ? $0.key : nil }
        for (tick, raw0) in source {
            let t = seconds(atTick: tick)
            var raw = raw0
            if let mk = lineMarker, raw.first == mk {
                raw.removeFirst()
                hadBreaks = true
                flush(paragraph: false)
            }
            // Lavoro sugli scalari Unicode: "\r\n" in Swift è un unico carattere.
            var u = Array(raw.unicodeScalars)
            var leadingBreaks = 0, leadingPara = false
            while let f = u.first, f == "\r" || f == "\n" || f == "/" || f == "\\" {
                if f == "\\" { leadingPara = true }
                if f == "\n" || f == "/" || f == "\\" { leadingBreaks += 1 } else if u.count > 1 && u[1] == "\n" { } else { leadingBreaks += 1 }
                u.removeFirst()
            }
            var trailingBreaks = 0
            while let l = u.last, l == "\r" || l == "\n" {
                if l == "\n" || !(trailingBreaks > 0) { trailingBreaks += 1 }
                u.removeLast()
            }
            if leadingBreaks > 0 { hadBreaks = true; flush(paragraph: leadingPara || leadingBreaks >= 2) }
            var text = String(String.UnicodeScalarView(u.filter { $0.value >= 32 || $0 == "\t" }))
            text = text.replacingOccurrences(of: "\t", with: " ")
            // Righe intere in un solo evento (alcuni file): spezzo agli a capo interni.
            let pieces = text.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            for (i, piece) in pieces.enumerated() {
                if i > 0 { hadBreaks = true; flush(paragraph: false) }
                if !piece.isEmpty { line.syllables.append(LyricSyllable(text: piece, time: t)) }
            }
            if trailingBreaks > 0 { hadBreaks = true; flush(paragraph: trailingBreaks >= 2) }
        }
        flush(paragraph: false)
        // Testo a righe intere (un evento per riga): le sillabe seguono le note della melodia, come in Win Live.
        alignWholeLinesToMelody(&lyrics)
        // Nessun a capo nel file, o righe troppo lunghe: divido alle pause e a ~42 caratteri.
        lyrics.lines = lyrics.lines.flatMap { KaraokeLyrics.splitLongLine($0, forceByPauses: !hadBreaks) }
        return lyrics
    }
}

extension MIDIFile {
    /// Messaggi SysEx M-Live (produttore 00 20 24): tipo e testo.
    private func mLiveMessages() -> [(t: Double, type: UInt8, text: String)] {
        var out: [(Double, UInt8, String)] = []
        for e in events {
            guard case .sysex(let d) = e.kind, d.count >= 5, d[0] == 0x00, d[1] == 0x20, d[2] == 0x24 else { continue }
            var body = Array(d.dropFirst(5))
            if body.last == 0xF7 { body.removeLast() }
            let text = TextDecoding.decode(body.filter { $0 != 0x0A && $0 != 0x0D }).trimmingCharacters(in: .whitespaces)
            out.append((seconds(atTick: e.tick), d[4], text))
        }
        return out.map { (t: $0.0, type: $0.1, text: $0.2) }
    }

    var hasMLiveData: Bool { !mLiveMessages().isEmpty }

    /// Testo delle basi M-Live: le righe arrivano a "pagine" di 4 (tipi 04–07, mostrate in anticipo);
    /// ogni messaggio di tipo 08 porta il canto alla riga successiva; le sillabe seguono poi la melodia.
    func mLiveLyrics() -> KaraokeLyrics {
        let msgs = mLiveMessages()
        guard !msgs.isEmpty else { return KaraokeLyrics() }
        var lyr = KaraokeLyrics()
        let firstChord = msgs.first { $0.type == 0x01 }?.t ?? .infinity
        // Intestazione (prima della musica): titolo e artista.
        for m in msgs where m.t < min(firstChord, 1.0) && (0x04...0x07).contains(m.type) && !m.text.isEmpty {
            let clean = m.text.trimmingCharacters(in: CharacterSet(charactersIn: "\"()"))
            if m.type == 0x04, lyr.title == nil { lyr.title = clean }
            else if m.type == 0x05, lyr.artist == nil { lyr.artist = clean }
        }
        // Righe in ordine di comparsa (dopo l'intestazione), e segnali di avanzamento.
        var pending: [String] = []
        var cues: [Double] = []
        var pageBreaks: [Int] = []
        for m in msgs where m.t >= min(firstChord, 1.0) || m.type == 0x08 {
            switch m.type {
            case 0x04...0x07:
                if m.type == 0x04, !pending.isEmpty { pageBreaks.append(pending.count) }
                if !m.text.isEmpty { pending.append(m.text) }
            case 0x08:
                if m.t >= min(firstChord, 1.0) - 0.5 { cues.append(m.t) }
            default: break
            }
        }
        // Se ci sono più segnali che righe, i primi sono il conteggio iniziale.
        if cues.count > pending.count { cues.removeFirst(cues.count - pending.count) }
        var t0 = msgs.first(where: { (0x04...0x07).contains($0.type) && $0.t >= min(firstChord, 1.0) })?.t ?? 0
        for (i, text) in pending.enumerated() {
            let t = i < cues.count ? cues[i] : t0 + 4
            t0 = t
            var line = LyricLine(syllables: [LyricSyllable(text: text, time: t)])
            line.endsParagraph = pageBreaks.contains(i + 1)
            lyr.lines.append(line)
        }
        alignWholeLinesToMelody(&lyr)
        lyr.lines = lyr.lines.flatMap { KaraokeLyrics.splitLongLine($0, forceByPauses: false) }
        return lyr
    }

    /// Accordi scritti nel file dal produttore (M-Live tipo 01, es. "Ebm", "Gb/Db").
    func embeddedChords() -> [ChordEvent] {
        mLiveMessages().filter { $0.type == 0x01 && !$0.text.isEmpty }.compactMap { m in
            Chord.parse(m.text).map { ChordEvent(time: m.t, chord: $0) }
        }
    }

    /// Per le righe scritte in un solo evento: divido in sillabe e assegno a ciascuna l'attacco
    /// di una nota della melodia (traccia rilevata automaticamente) tra l'inizio di questa riga e la successiva.
    func alignWholeLinesToMelody(_ lyrics: inout KaraokeLyrics) {
        let wholeLines = lyrics.lines.filter { l in l.syllables.contains { $0.text.trimmingCharacters(in: .whitespaces).contains(" ") } }
        guard !wholeLines.isEmpty, Double(wholeLines.count) >= Double(lyrics.lines.count) * 0.5 else { return }
        let melody = MelodyDetector.detect(self, lyrics: lyrics)
        let onsets = notes.filter { $0.channel == melody }.map { seconds(atTick: $0.startTick) }.sorted()
        // Anticipo del testo sul canto (le righe compaiono prima): mediana tra inizio riga e prima nota.
        var deltas: [Double] = []
        for l in lyrics.lines {
            let st = l.startTime
            guard st >= 0, let first = onsets.first(where: { $0 >= st - 0.1 }) else { continue }
            let d = first - st
            if d >= 0 && d < 4 { deltas.append(d) }
        }
        deltas.sort()
        let lead = deltas.isEmpty ? 0 : deltas[deltas.count / 2]
        for i in lyrics.lines.indices {
            let line = lyrics.lines[i]
            guard line.syllables.contains(where: { $0.text.trimmingCharacters(in: .whitespaces).contains(" ") }),
                  let start = line.syllables.first?.time, start >= 0 else { continue }
            let next = i + 1 < lyrics.lines.count ? lyrics.lines[i + 1].startTime : -1
            let end = next > start ? next : start + 8
            let syl = Syllabifier.syllables(line.text)
            guard !syl.isEmpty else { continue }
            let ns = onsets.filter { $0 >= start + lead - 0.25 && $0 < end + lead - 0.25 }
            var times: [Double] = []
            if ns.count >= syl.count {
                if Double(ns.count) <= Double(syl.count) * 1.6 { times = Array(ns.prefix(syl.count)) }
                else { times = (0..<syl.count).map { ns[Int(Double($0) * Double(ns.count) / Double(syl.count))] } }
            } else {
                times = ns
                let from = ns.last.map { $0 + 0.25 } ?? (start + lead)
                let remaining = syl.count - ns.count
                let span = max(0.3, (end + lead - from) * 0.85)
                for k in 0..<remaining { times.append(from + span * Double(k) / Double(max(1, remaining))) }
            }
            var out = LyricLine(syllables: zip(syl, times).map { LyricSyllable(text: $0.text, time: $1) })
            out.endsParagraph = line.endsParagraph
            lyrics.lines[i] = out
        }
    }
}

extension KaraokeLyrics {
    /// Divide una riga troppo lunga per lo schermo: alle pause di canto (>0,9 s) o al confine di parola.
    static func splitLongLine(_ line: LyricLine, forceByPauses: Bool, maxChars: Int = 42) -> [LyricLine] {
        guard line.text.count > maxChars || (forceByPauses && line.syllables.count > 6) else { return [line] }
        var out: [LyricLine] = []
        var cur = LyricLine()
        var len = 0
        for (i, s) in line.syllables.enumerated() {
            let gap = i > 0 && s.time >= 0 && line.syllables[i - 1].time >= 0 ? s.time - line.syllables[i - 1].time : 0
            let wordStart = i == 0 || line.syllables[i - 1].text.hasSuffix(" ") || s.text.hasPrefix(" ")
            if !cur.syllables.isEmpty && wordStart && ((forceByPauses && gap > 0.9) || len + s.text.count > maxChars) {
                out.append(cur); cur = LyricLine(); len = 0
            }
            cur.syllables.append(s)
            len += s.text.count
        }
        if !cur.syllables.isEmpty { cur.endsParagraph = line.endsParagraph; out.append(cur) }
        return out
    }
}

enum TextDecoding {
    static func decode(_ data: [UInt8]) -> String {
        if let s = String(bytes: data, encoding: .utf8) { return s }
        return String(bytes: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
}
