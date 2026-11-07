import Foundation

/// Rapporto leggibile su cosa contiene un brano riguardo al testo (per capire perché non si vede).
enum LyricsDiagnostics {
    static func report(for url: URL) -> String {
        var r: [String] = []
        let ext = url.pathExtension.lowercased()
        r.append("File: \(url.lastPathComponent)")
        if let a = try? FileManager.default.attributesOfItem(atPath: url.path), let s = a[.size] as? Int { r.append("Dimensione: \(s) byte") }
        if let side = SongSidecar.load(for: url) {
            r.append("Salvataggio FPM (.fpm.json): presente, righe testo \(side.lyrics?.lines.count ?? 0)")
        }
        if ["mid", "midi", "kar", "rmi"].contains(ext) {
            guard let m = try? MIDIFile(url: url) else { r.append("MIDI: NON LEGGIBILE"); return r.joined(separator: "\n") }
            r.append("MIDI formato \(m.format), PPQ \(m.ppq), tracce con eventi \(Set(m.events.map { $0.track }).count), durata \(Int(m.duration)) s")
            var groups: [String: [String]] = [:]
            for e in m.events {
                guard case .meta(let type, let data) = e.kind, [1, 3, 5, 6].contains(Int(type)) else { continue }
                let name = ["", "Text", "", "TrackName", "", "Lyric", "Marker"][Int(type)]
                groups["\(name) traccia \(e.track)", default: []].append(TextDecoding.decode(data))
            }
            for (k, v) in groups.sorted(by: { $0.key < $1.key }) {
                let sample = v.prefix(6).map { s in s.unicodeScalars.map { $0 == "\r" ? "⏎" : ($0 == "\n" ? "↵" : String($0)) }.joined() }
                r.append("  \(k): \(v.count) eventi → " + sample.map { "«\($0)»" }.joined(separator: " "))
            }
            let l = m.karaokeLyrics()
            r.append("Testo ricavato: \(l.lines.count) righe, \(l.flat.count) sillabe")
            for line in l.lines.prefix(3) { r.append("  [\(String(format: "%.1f", line.startTime)) s] \(line.text)") }
        } else {
            let base = url.deletingPathExtension()
            for e in ["lrc", "srt", "kar", "mid", "txt", "cdg"] {
                for v in [e, e.uppercased()] where FileManager.default.fileExists(atPath: base.appendingPathExtension(v).path) {
                    r.append("File abbinato trovato: \(base.lastPathComponent).\(v)")
                }
            }
            if let d = try? Data(contentsOf: url, options: .mappedIfSafe) {
                let b = [UInt8](d.prefix(10))
                if b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 {
                    r.append("Tag ID3v2.\(b[3]) presente, frame: " + ID3Lyrics.frameIDs(d).joined(separator: " "))
                } else {
                    r.append("Nessun tag ID3v2 all'inizio del file")
                }
                if let f = ID3Lyrics.parse(d) { r.append("Testo nel tag: \(f.source), \(f.lyrics.lines.count) righe") }
            }
            if let f = LyricsSources.find(for: url) {
                r.append("Testo trovato: \(f.source), \(f.lyrics.lines.count) righe")
                for line in f.lyrics.lines.prefix(3) { r.append("  [\(String(format: "%.1f", line.startTime)) s] \(line.text)") }
            } else {
                r.append("Nessun testo trovato nel file né in file abbinati")
            }
        }
        return r.joined(separator: "\n")
    }
}

extension ID3Lyrics {
    /// Elenco dei frame del tag (per la diagnostica).
    static func frameIDs(_ d: Data) -> [String] {
        let b = [UInt8](d.prefix(10))
        guard b.count == 10 else { return [] }
        let major = Int(b[3])
        let size = Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F)
        guard d.count >= 10 + size else { return [] }
        let tag = [UInt8](d[10..<(10 + size)])
        var out: [String] = []
        var p = 0
        let idLen = major == 2 ? 3 : 4, hdr = major == 2 ? 6 : 10
        while p + hdr <= tag.count, out.count < 60 {
            guard let id = String(bytes: tag[p..<(p + idLen)], encoding: .ascii), id.first?.isLetter == true else { break }
            let fs: Int
            if major == 2 { fs = Int(tag[p + 3]) << 16 | Int(tag[p + 4]) << 8 | Int(tag[p + 5]) }
            else if major == 4 { fs = Int(tag[p + 4] & 0x7F) << 21 | Int(tag[p + 5] & 0x7F) << 14 | Int(tag[p + 6] & 0x7F) << 7 | Int(tag[p + 7] & 0x7F) }
            else { fs = Int(tag[p + 4]) << 24 | Int(tag[p + 5]) << 16 | Int(tag[p + 6]) << 8 | Int(tag[p + 7]) }
            guard fs > 0 else { break }
            out.append(id)
            p += hdr + fs
        }
        return out
    }
}
