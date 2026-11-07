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
    func karaokeLyrics() -> KaraokeLyrics {
        var textEvents: [(Int, String)] = []
        var lyricEvents: [(Int, String)] = []
        var karHeaders: [String] = []
        for e in events {
            guard case .meta(let type, let data) = e.kind else { continue }
            let s = TextDecoding.decode(data)
            if type == 0x01 {
                if s.hasPrefix("@") { karHeaders.append(s); continue }
                textEvents.append((e.tick, s))
            } else if type == 0x05 {
                lyricEvents.append((e.tick, s))
            }
        }
        let isKar = !karHeaders.isEmpty || textEvents.contains { $0.1.hasPrefix("/") || $0.1.hasPrefix("\\") }
        let source = (isKar && textEvents.count > 10) || lyricEvents.count < 5 ? textEvents : lyricEvents
        var lyrics = KaraokeLyrics()
        for h in karHeaders where h.hasPrefix("@T") {
            let v = String(h.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if lyrics.title == nil { lyrics.title = v } else if lyrics.artist == nil { lyrics.artist = v }
        }
        guard source.count >= 5 else { return lyrics }
        var line = LyricLine()
        func flush(paragraph: Bool) {
            if !line.syllables.isEmpty { lyrics.lines.append(line) }
            line = LyricLine()
            if paragraph, !lyrics.lines.isEmpty { lyrics.lines[lyrics.lines.count - 1].endsParagraph = true }
        }
        for (tick, raw) in source {
            var s = raw
            let t = seconds(atTick: tick)
            if s.hasPrefix("\\") { flush(paragraph: true); s.removeFirst() }
            else if s.hasPrefix("/") { flush(paragraph: false); s.removeFirst() }
            var breakAfter = false, paraAfter = false
            if s.hasSuffix("\r\n") || s.hasSuffix("\n\n") { paraAfter = true }
            if s.hasSuffix("\r") || s.hasSuffix("\n") { breakAfter = true }
            s = s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            if !s.isEmpty { line.syllables.append(LyricSyllable(text: s, time: t)) }
            if breakAfter || paraAfter { flush(paragraph: paraAfter) }
        }
        flush(paragraph: false)
        return lyrics
    }
}

enum TextDecoding {
    static func decode(_ data: [UInt8]) -> String {
        if let s = String(bytes: data, encoding: .utf8) { return s }
        return String(bytes: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
}
