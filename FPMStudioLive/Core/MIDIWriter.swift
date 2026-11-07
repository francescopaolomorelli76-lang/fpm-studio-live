import Foundation

/// Scrive file MIDI standard di tipo 1.
struct MIDIWriter {
    struct TrackEvent {
        var tick: Int
        var bytes: [UInt8]
        /// A parità di tick: prima i meta, poi i note-off, poi controller/program, poi i note-on.
        var order: Int {
            guard let s = bytes.first else { return 0 }
            if s == 0xFF { return 0 }
            switch s & 0xF0 {
            case 0x80: return 1
            case 0x90: return bytes.count > 2 && bytes[2] == 0 ? 1 : 3
            default: return 2
            }
        }
    }

    var ppq: Int
    var tracks: [(name: String, events: [TrackEvent])] = []

    init(ppq: Int) { self.ppq = ppq }

    mutating func addTrack(_ name: String, _ events: [TrackEvent]) {
        tracks.append((name, events))
    }

    static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var out: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 { out.insert(UInt8((v & 0x7F) | 0x80), at: 0); v >>= 7 }
        return out
    }

    static func meta(_ type: UInt8, _ data: [UInt8]) -> [UInt8] { [0xFF, type] + vlq(data.count) + data }
    static func text(_ type: UInt8, _ s: String) -> [UInt8] { meta(type, Array(s.utf8)) }
    static func tempo(bpm: Double) -> [UInt8] {
        let us = Int(60_000_000 / max(1, bpm))
        return meta(0x51, [UInt8((us >> 16) & 0xFF), UInt8((us >> 8) & 0xFF), UInt8(us & 0xFF)])
    }

    func data() -> Data {
        var out: [UInt8] = Array("MThd".utf8) + [0, 0, 0, 6, 0, 1, UInt8(tracks.count >> 8), UInt8(tracks.count & 0xFF), UInt8(ppq >> 8), UInt8(ppq & 0xFF)]
        for t in tracks {
            var evs = t.events
            evs.insert(TrackEvent(tick: 0, bytes: MIDIWriter.text(0x03, t.name)), at: 0)
            evs = evs.enumerated().sorted { a, b in
                if a.element.tick != b.element.tick { return a.element.tick < b.element.tick }
                if a.element.order != b.element.order { return a.element.order < b.element.order }
                return a.offset < b.offset
            }.map { $0.element }
            var body: [UInt8] = []
            var last = 0
            for e in evs {
                body += MIDIWriter.vlq(e.tick - last) + e.bytes
                last = e.tick
            }
            body += [0x00, 0xFF, 0x2F, 0x00]
            let n = body.count
            out += Array("MTrk".utf8) + [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + body
        }
        return Data(out)
    }
}

extension MIDIFile {
    /// Eventi di tempo e metrica, da copiare nei MIDI generati.
    func conductorEvents() -> [MIDIWriter.TrackEvent] {
        var out: [MIDIWriter.TrackEvent] = []
        for e in events {
            if case .meta(let type, let data) = e.kind, type == 0x51 || type == 0x58 || type == 0x59 {
                out.append(.init(tick: e.tick, bytes: MIDIWriter.meta(type, data)))
            }
        }
        return out
    }

    /// Eventi di canale originali di un insieme di canali (per conservare basso e batteria).
    func channelEvents(_ channels: Set<Int>, remapTo: [Int: Int] = [:]) -> [MIDIWriter.TrackEvent] {
        var out: [MIDIWriter.TrackEvent] = []
        for e in events {
            if case .channel(let s, let d1, let d2) = e.kind, channels.contains(Int(s & 0x0F)) {
                let ch = remapTo[Int(s & 0x0F)] ?? Int(s & 0x0F)
                let st = (s & 0xF0) | UInt8(ch)
                let cmd = s & 0xF0
                out.append(.init(tick: e.tick, bytes: (cmd == 0xC0 || cmd == 0xD0) ? [st, d1] : [st, d1, d2]))
            }
        }
        return out
    }

    /// Testo karaoke come eventi Lyric (FF05), per esportare un .kar/.mid cantabile.
    static func lyricEvents(_ lyrics: KaraokeLyrics, using midi: MIDIFile) -> [MIDIWriter.TrackEvent] {
        var out: [MIDIWriter.TrackEvent] = []
        for (li, l) in lyrics.lines.enumerated() {
            for (si, s) in l.syllables.enumerated() where s.time >= 0 {
                var txt = s.text
                if si == l.syllables.count - 1 { txt += l.endsParagraph ? "\r\n" : "\r" }
                _ = li
                out.append(.init(tick: midi.tick(atSeconds: s.time), bytes: MIDIWriter.text(0x05, txt)))
            }
        }
        return out
    }
}
