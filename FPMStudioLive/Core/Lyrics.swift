import Foundation

/// Una sillaba (o parola) del testo con il suo istante in secondi, a velocità originale.
/// `time < 0` significa "non ancora sincronizzata".
struct LyricSyllable: Codable, Hashable {
    var text: String
    var time: Double
    var chord: Chord? = nil
}

struct LyricLine: Codable, Hashable {
    var syllables: [LyricSyllable] = []
    var endsParagraph: Bool = false

    var text: String { syllables.map { $0.text }.joined().trimmingCharacters(in: .whitespaces) }
    var startTime: Double { syllables.first(where: { $0.time >= 0 })?.time ?? -1 }
    var lastTime: Double { syllables.last(where: { $0.time >= 0 })?.time ?? -1 }
    var isSynced: Bool { !syllables.isEmpty && syllables.allSatisfy { $0.time >= 0 } }
}

struct KaraokeLyrics: Codable, Hashable {
    var title: String? = nil
    var artist: String? = nil
    var lines: [LyricLine] = []

    var isEmpty: Bool { lines.isEmpty }
    var isFullySynced: Bool { !lines.isEmpty && lines.allSatisfy { $0.isSynced } }

    /// Tutte le sillabe con indice di riga, in ordine.
    var flat: [(line: Int, index: Int, syllable: LyricSyllable)] {
        var out: [(Int, Int, LyricSyllable)] = []
        for (li, l) in lines.enumerated() { for (si, s) in l.syllables.enumerated() { out.append((li, si, s)) } }
        return out.map { (line: $0.0, index: $0.1, syllable: $0.2) }
    }

    /// Accordi scritti a mano sulle sillabe.
    var chordEvents: [ChordEvent] {
        var out: [ChordEvent] = []
        for l in lines { for s in l.syllables where s.chord != nil && s.time >= 0 { out.append(ChordEvent(time: s.time, chord: s.chord)) } }
        return out.sorted { $0.time < $1.time }
    }

    /// Riga attiva all'istante `t` (secondi del brano).
    func lineIndex(at t: Double) -> Int? {
        var current: Int?
        for (i, l) in lines.enumerated() {
            let st = l.startTime
            if st >= 0 && st <= t + 0.05 { current = i } else if st > t { break }
        }
        return current
    }

    /// Quanta parte della riga è già cantata (0...1) per sillaba: restituisce l'indice della sillaba e la frazione.
    func progress(line: Int, at t: Double) -> (syllable: Int, fraction: Double) {
        guard lines.indices.contains(line) else { return (0, 0) }
        let sy = lines[line].syllables
        var idx = -1
        for (i, s) in sy.enumerated() where s.time >= 0 && s.time <= t { idx = i }
        if idx < 0 { return (-1, 0) }
        let start = sy[idx].time
        var end = start + 0.6
        if idx + 1 < sy.count, sy[idx + 1].time > start { end = sy[idx + 1].time }
        else if line + 1 < lines.count, lines[line + 1].startTime > start { end = min(start + 1.2, lines[line + 1].startTime) }
        let f = max(0, min(1, (t - start) / max(0.05, end - start)))
        return (idx, f)
    }

    // MARK: - Formato dell'editor
    //
    // Una riga di testo per ogni riga cantata; riga vuota = fine strofa.
    // Le sillabe di una parola si separano con "/" (can/ta/re).
    // Gli accordi vanno tra parentesi quadre prima della sillaba: [Lam]Nel blu di[Re]pinto.

    func editorText(notation: ChordNotation) -> String {
        var out: [String] = []
        for l in lines {
            var s = ""
            var prevEndsWord = true
            for syl in l.syllables {
                if !prevEndsWord { s += "/" }
                if let c = syl.chord { s += "[" + c.name(notation) + "]" }
                let endsWord = syl.text.hasSuffix(" ") || syl.text.hasSuffix("-")
                s += syl.text.trimmingCharacters(in: .whitespaces) + (endsWord ? " " : "")
                prevEndsWord = endsWord
            }
            out.append(s.trimmingCharacters(in: .whitespaces))
            if l.endsParagraph { out.append("") }
        }
        return out.joined(separator: "\n")
    }

    /// Ricostruisce il testo dall'editor mantenendo i tempi delle righe rimaste uguali (stesso numero di sillabe).
    static func fromEditorText(_ text: String, keeping old: KaraokeLyrics) -> KaraokeLyrics {
        var result = KaraokeLyrics(title: old.title, artist: old.artist, lines: [])
        let rows = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var oldIndex = 0
        for row in rows {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !result.lines.isEmpty { result.lines[result.lines.count - 1].endsParagraph = true }
                continue
            }
            var line = LyricLine(syllables: parseRow(trimmed))
            if oldIndex < old.lines.count, old.lines[oldIndex].syllables.count == line.syllables.count {
                for i in line.syllables.indices { line.syllables[i].time = old.lines[oldIndex].syllables[i].time }
            }
            oldIndex += 1
            result.lines.append(line)
        }
        return result
    }

    private static func parseRow(_ row: String) -> [LyricSyllable] {
        var out: [LyricSyllable] = []
        var pendingChord: Chord?
        var current = ""
        var i = row.startIndex
        func emit(endsWord: Bool) {
            if current.isEmpty && pendingChord == nil { return }
            out.append(LyricSyllable(text: current + (endsWord ? " " : ""), time: -1, chord: pendingChord))
            current = ""; pendingChord = nil
        }
        while i < row.endIndex {
            let c = row[i]
            if c == "[" , let close = row[i...].firstIndex(of: "]") {
                let name = String(row[row.index(after: i)..<close])
                if !current.isEmpty { emit(endsWord: false) }
                pendingChord = Chord.parse(name)
                i = row.index(after: close)
                continue
            }
            if c == " " { emit(endsWord: true) }
            else if c == "/" { emit(endsWord: false) }
            else { current.append(c) }
            i = row.index(after: i)
        }
        emit(endsWord: true)
        if let last = out.indices.last { out[last].text = out[last].text.trimmingCharacters(in: .whitespaces) }
        return out
    }

    /// Esporta in formato LRC "avanzato" (tempi per riga).
    func lrc() -> String {
        var s = ""
        if let t = title { s += "[ti:\(t)]\n" }
        if let a = artist { s += "[ar:\(a)]\n" }
        for l in lines where l.startTime >= 0 {
            let t = l.startTime
            s += String(format: "[%02d:%05.2f]", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) + l.text + "\n"
        }
        return s
    }

    /// Importa un file .lrc (tempi per riga, le sillabe vengono distribuite uniformemente).
    static func fromLRC(_ text: String) -> KaraokeLyrics {
        var lyr = KaraokeLyrics()
        var timed: [(Double, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) { times.append(m * 60 + sec) }
                else if parts.count == 2 {
                    if parts[0] == "ti" { lyr.title = String(parts[1]) }
                    if parts[0] == "ar" { lyr.artist = String(parts[1]) }
                }
                rest = rest[rest.index(after: close)...]
            }
            for t in times { timed.append((t, String(rest))) }
        }
        timed.sort { $0.0 < $1.0 }
        for (i, (t, txt)) in timed.enumerated() {
            let next = i + 1 < timed.count ? timed[i + 1].0 : t + 4
            let words = txt.split(separator: " ").map(String.init)
            if words.isEmpty {
                if !lyr.lines.isEmpty { lyr.lines[lyr.lines.count - 1].endsParagraph = true }
                continue
            }
            let span = max(0.5, (next - t) * 0.85)
            let line = LyricLine(syllables: words.enumerated().map { j, w in
                LyricSyllable(text: w + (j < words.count - 1 ? " " : ""), time: t + span * Double(j) / Double(words.count))
            })
            lyr.lines.append(line)
        }
        return lyr
    }
}

// MARK: - Struttura del brano

enum SectionKind: String, Codable, CaseIterable, Identifiable {
    case intro, verse, preChorus, chorus, bridge, instrumental, outro
    var id: String { rawValue }
    var label: String {
        switch self {
        case .intro: return "INTRO"
        case .verse: return "VERSE"
        case .preChorus: return "PRE-CHORUS"
        case .chorus: return "CHORUS"
        case .bridge: return "BRIDGE"
        case .instrumental: return "SOLO"
        case .outro: return "OUTRO"
        }
    }
    var italian: String {
        switch self {
        case .intro: return "Introduzione"
        case .verse: return "Strofa"
        case .preChorus: return "Pre-ritornello"
        case .chorus: return "Ritornello"
        case .bridge: return "Ponte"
        case .instrumental: return "Strumentale"
        case .outro: return "Finale"
        }
    }
}

struct SongSection: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: SectionKind
    var start: Double   // secondi
    var end: Double
    var number: Int = 1 // VERSE 1, VERSE 2...

    var title: String {
        [.verse, .chorus, .preChorus, .instrumental].contains(kind) ? "\(kind.label) \(number)" : kind.label
    }
}

// MARK: - File di accompagnamento (testo, accordi, struttura) salvato accanto al brano

struct SongSidecar: Codable {
    var version = 1
    var lyrics: KaraokeLyrics?
    var chords: [ChordEvent]?
    var sections: [SongSection]?
    var lyricsOffset: Double = 0
    var defaultTranspose: Int = 0
    var defaultTempo: Double = 1
    var melodyChannel: Int?

    static func url(for song: URL) -> URL {
        song.deletingPathExtension().appendingPathExtension(song.pathExtension + ".fpm.json")
    }

    private static func fallbackURL(for song: URL) -> URL {
        let key = song.path.data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        return AppPaths.sidecars.appendingPathComponent(String(key.suffix(120)) + ".json")
    }

    static func load(for song: URL) -> SongSidecar? {
        for u in [url(for: song), fallbackURL(for: song)] {
            if let d = try? Data(contentsOf: u), let s = try? JSONDecoder().decode(SongSidecar.self, from: d) { return s }
        }
        return nil
    }

    func save(for song: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let d = try enc.encode(self)
        do { try d.write(to: SongSidecar.url(for: song), options: .atomic) }
        catch { try d.write(to: SongSidecar.fallbackURL(for: song), options: .atomic) }
    }
}

enum AppPaths {
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FPM Studio Live", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var sidecars: URL { sub("Testi") }
    static var renderCache: URL { sub("Cache basi MIDI") }
    static var exports: URL {
        let u = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FPM Studio Live", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static func sub(_ n: String) -> URL {
        let u = support.appendingPathComponent(n, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
