import Foundation

/// Tutte le fonti di testo per i brani audio/video:
/// tag ID3 dell'MP3 (SYLT sincronizzato, USLT non sincronizzato o in formato LRC),
/// file abbinati con lo stesso nome (.lrc, .srt, .kar/.mid, .txt).
enum LyricsSources {
    struct Found {
        var lyrics: KaraokeLyrics
        var source: String          // descrizione per l'utente
        var synced: Bool
    }

    /// Cerca il testo di un file audio/video. `duration` serve solo per i testi non sincronizzati.
    static func find(for url: URL) -> Found? {
        let base = url.deletingPathExtension()
        // 1. File abbinati (hanno la precedenza: li ha messi l'utente).
        for ext in ["lrc", "LRC"] {
            if let s = readText(base.appendingPathExtension(ext)) {
                let l = KaraokeLyrics.fromLRC(s)
                if !l.isEmpty { return Found(lyrics: l, source: "file .lrc", synced: true) }
            }
        }
        for ext in ["srt", "SRT"] {
            if let s = readText(base.appendingPathExtension(ext)) {
                let l = fromSRT(s)
                if !l.isEmpty { return Found(lyrics: l, source: "file .srt", synced: true) }
            }
        }
        for ext in ["kar", "KAR", "mid", "MID", "midi"] {
            let u = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: u.path), let m = try? MIDIFile(url: u) {
                let l = m.karaokeLyrics()
                if !l.isEmpty { return Found(lyrics: l, source: "file .\(ext.lowercased()) abbinato", synced: true) }
            }
        }
        // 2. Tag ID3 dentro l'MP3.
        if let d = try? Data(contentsOf: url, options: .mappedIfSafe), let id3 = ID3Lyrics.parse(d) {
            return id3
        }
        // 3. Testo semplice (non sincronizzato).
        for ext in ["txt", "TXT"] {
            if let s = readText(base.appendingPathExtension(ext)) {
                let l = unsynced(s)
                if !l.isEmpty { return Found(lyrics: l, source: "file .txt (da sincronizzare)", synced: false) }
            }
        }
        return nil
    }

    static func readText(_ u: URL) -> String? {
        guard let d = try? Data(contentsOf: u) else { return nil }
        if let s = String(data: d, encoding: .utf8) { return s }
        if d.count >= 2 && ((d[0] == 0xFF && d[1] == 0xFE) || (d[0] == 0xFE && d[1] == 0xFF)) { return String(data: d, encoding: .utf16) }
        return String(data: d, encoding: .windowsCP1252)
    }

    /// Testo senza tempi: una riga per verso, riga vuota = fine strofa.
    static func unsynced(_ text: String) -> KaraokeLyrics {
        var l = KaraokeLyrics()
        for raw in text.components(separatedBy: .newlines) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { if !l.lines.isEmpty { l.lines[l.lines.count - 1].endsParagraph = true }; continue }
            let words = t.split(separator: " ").map(String.init)
            l.lines.append(LyricLine(syllables: words.enumerated().map { i, w in
                LyricSyllable(text: w + (i < words.count - 1 ? " " : ""), time: -1)
            }))
        }
        return l
    }

    /// Sottotitoli SRT: ogni blocco diventa una riga, parole distribuite nella durata del blocco.
    static func fromSRT(_ text: String) -> KaraokeLyrics {
        var l = KaraokeLyrics()
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        func ts(_ s: String) -> Double? {
            let p = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
            guard p.count == 3, let h = Double(p[0]), let m = Double(p[1]), let sec = Double(p[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        }
        for b in blocks {
            let rows = b.split(separator: "\n").map(String.init)
            guard let timeRow = rows.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = rows[timeRow].components(separatedBy: "-->")
            guard parts.count == 2, let a = ts(parts[0]), let e = ts(parts[1]) else { continue }
            let txt = rows[(timeRow + 1)...].joined(separator: " ")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let words = txt.split(separator: " ").map(String.init)
            guard !words.isEmpty else { continue }
            let span = max(0.3, (e - a) * 0.9)
            l.lines.append(LyricLine(syllables: words.enumerated().map { i, w in
                LyricSyllable(text: w + (i < words.count - 1 ? " " : ""), time: a + span * Double(i) / Double(words.count))
            }))
        }
        return l
    }
}

/// Lettore dei testi nei tag ID3v2 (v2.2, v2.3, v2.4).
enum ID3Lyrics {
    static func parse(_ d: Data) -> LyricsSources.Found? {
        let b = [UInt8](d.prefix(10))
        guard b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return nil }   // "ID3"
        let major = Int(b[3])
        let flags = b[5]
        let size = Int(b[6] & 0x7F) << 21 | Int(b[7] & 0x7F) << 14 | Int(b[8] & 0x7F) << 7 | Int(b[9] & 0x7F)
        guard d.count >= 10 + size else { return nil }
        var tag = [UInt8](d[10..<(10 + size)])
        if flags & 0x80 != 0 { tag = deunsync(tag) }
        var p = 0
        if flags & 0x40 != 0 && major >= 3, tag.count >= 4 {   // header esteso
            let ext = major == 4 ? (Int(tag[0] & 0x7F) << 21 | Int(tag[1] & 0x7F) << 14 | Int(tag[2] & 0x7F) << 7 | Int(tag[3] & 0x7F))
                                 : (Int(tag[0]) << 24 | Int(tag[1]) << 16 | Int(tag[2]) << 8 | Int(tag[3])) + 4
            p = min(tag.count, ext)
        }
        var sylt: KaraokeLyrics?
        var uslt: String?
        let idLen = major == 2 ? 3 : 4, hdrLen = major == 2 ? 6 : 10
        while p + hdrLen <= tag.count {
            let id = String(bytes: tag[p..<(p + idLen)], encoding: .ascii) ?? ""
            if id.first == "\0" || id.isEmpty { break }
            let fsize: Int
            if major == 2 { fsize = Int(tag[p + 3]) << 16 | Int(tag[p + 4]) << 8 | Int(tag[p + 5]) }
            else if major == 4 { fsize = Int(tag[p + 4] & 0x7F) << 21 | Int(tag[p + 5] & 0x7F) << 14 | Int(tag[p + 6] & 0x7F) << 7 | Int(tag[p + 7] & 0x7F) }
            else { fsize = Int(tag[p + 4]) << 24 | Int(tag[p + 5]) << 16 | Int(tag[p + 6]) << 8 | Int(tag[p + 7]) }
            let start = p + hdrLen
            guard fsize > 0, start + fsize <= tag.count else { break }
            var body = Array(tag[start..<(start + fsize)])
            if major == 4, tag[p + 9] & 0x02 != 0 { body = deunsync(body) }
            if id == "SYLT" || id == "SLT", sylt == nil { sylt = parseSYLT(body) }
            if id == "USLT" || id == "ULT", uslt == nil { uslt = parseUSLT(body) }
            p = start + fsize
        }
        if let s = sylt, !s.isEmpty { return .init(lyrics: s, source: "tag ID3 sincronizzato (SYLT)", synced: true) }
        if let u = uslt, !u.isEmpty {
            if u.range(of: #"\[\d{1,2}:\d{2}"#, options: .regularExpression) != nil {
                let l = KaraokeLyrics.fromLRC(u)
                if !l.isEmpty { return .init(lyrics: l, source: "tag ID3 (testo LRC)", synced: true) }
            }
            return .init(lyrics: LyricsSources.unsynced(u), source: "tag ID3 non sincronizzato (da sincronizzare)", synced: false)
        }
        return nil
    }

    static func deunsync(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            out.append(b[i])
            if b[i] == 0xFF && i + 1 < b.count && b[i + 1] == 0x00 { i += 1 }
            i += 1
        }
        return out
    }

    /// Legge una stringa terminata secondo la codifica ID3; restituisce testo e posizione successiva.
    static func string(_ b: [UInt8], from: Int, encoding: UInt8) -> (String, Int) {
        var i = from
        if encoding == 1 || encoding == 2 {
            while i + 1 < b.count && !(b[i] == 0 && b[i + 1] == 0) { i += 2 }
            let bytes = Array(b[from..<min(i, b.count)])
            let s: String
            if encoding == 2 { s = String(bytes: bytes, encoding: .utf16BigEndian) ?? "" }
            else if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF { s = String(bytes: bytes.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
            else if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE { s = String(bytes: bytes.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
            else { s = String(bytes: bytes, encoding: .utf16LittleEndian) ?? "" }
            return (s, min(b.count, i + 2))
        }
        while i < b.count && b[i] != 0 { i += 1 }
        let bytes = Array(b[from..<min(i, b.count)])
        let s = encoding == 3 ? (String(bytes: bytes, encoding: .utf8) ?? "") : (String(bytes: bytes, encoding: .isoLatin1) ?? "")
        return (s, min(b.count, i + 1))
    }

    static func parseUSLT(_ b: [UInt8]) -> String? {
        guard b.count > 4 else { return nil }
        let enc = b[0]
        let (_, afterDesc) = string(b, from: 4, encoding: enc)
        let (text, _) = string(b, from: afterDesc, encoding: enc)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseSYLT(_ b: [UInt8]) -> KaraokeLyrics? {
        guard b.count > 6 else { return nil }
        let enc = b[0]
        let format = b[4]                   // 1 = frame MPEG, 2 = millisecondi
        guard format == 2 else { return nil }
        var (_, p) = string(b, from: 6, encoding: enc)
        var items: [(Double, String)] = []
        while p < b.count {
            let (text, next) = string(b, from: p, encoding: enc)
            guard next + 4 <= b.count else { break }
            let ms = Int(b[next]) << 24 | Int(b[next + 1]) << 16 | Int(b[next + 2]) << 8 | Int(b[next + 3])
            items.append((Double(ms) / 1000, text))
            p = next + 4
        }
        guard !items.isEmpty else { return nil }
        var l = KaraokeLyrics()
        var line = LyricLine()
        var hadBreaks = false
        for (t, raw) in items {
            var u = Array(raw.unicodeScalars)
            var lead = 0
            while let f = u.first, f == "\r" || f == "\n" || f == "/" || f == "\\" { lead += 1; u.removeFirst() }
            var trail = 0
            while let e = u.last, e == "\r" || e == "\n" { trail += 1; u.removeLast() }
            if lead > 0 {
                hadBreaks = true
                if !line.syllables.isEmpty { l.lines.append(line) }
                line = LyricLine()
                if lead >= 2, !l.lines.isEmpty { l.lines[l.lines.count - 1].endsParagraph = true }
            }
            let text = String(String.UnicodeScalarView(u))
            if !text.isEmpty { line.syllables.append(LyricSyllable(text: text, time: t)) }
            if trail > 0 {
                hadBreaks = true
                if !line.syllables.isEmpty { l.lines.append(line) }
                line = LyricLine()
            }
        }
        if !line.syllables.isEmpty { l.lines.append(line) }
        l.lines = l.lines.flatMap { KaraokeLyrics.splitLongLine($0, forceByPauses: !hadBreaks) }
        return l
    }
}
