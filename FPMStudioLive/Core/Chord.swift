import Foundation

enum ChordNotation: String, CaseIterable, Identifiable, Codable {
    case italian, english
    var id: String { rawValue }
    var label: String { self == .italian ? "Italiano (Do Re Mi)" : "Inglese (C D E)" }
}

/// Accordo: fondamentale (0 = Do/C), qualità e basso opzionale (rivolto).
struct Chord: Codable, Hashable {
    var root: Int
    var quality: Quality
    var bass: Int?

    enum Quality: String, Codable, CaseIterable {
        case major = "", minor = "m", seventh = "7", major7 = "maj7", minor7 = "m7"
        case sus4 = "sus4", sus2 = "sus2", dim = "dim", halfDim = "m7b5", aug = "aug"
        case sixth = "6", minor6 = "m6", add9 = "add9", ninth = "9", dim7 = "dim7"

        var intervals: [Int] {
            switch self {
            case .major: return [0, 4, 7]
            case .minor: return [0, 3, 7]
            case .seventh: return [0, 4, 7, 10]
            case .major7: return [0, 4, 7, 11]
            case .minor7: return [0, 3, 7, 10]
            case .sus4: return [0, 5, 7]
            case .sus2: return [0, 2, 7]
            case .dim: return [0, 3, 6]
            case .halfDim: return [0, 3, 6, 10]
            case .aug: return [0, 4, 8]
            case .sixth: return [0, 4, 7, 9]
            case .minor6: return [0, 3, 7, 9]
            case .add9: return [0, 4, 7, 14]
            case .ninth: return [0, 4, 7, 10, 14]
            case .dim7: return [0, 3, 6, 9]
            }
        }
        var isMinor: Bool { [.minor, .minor7, .halfDim, .dim, .minor6, .dim7].contains(self) }

        /// Suffisso mostrato a schermo.
        func display(_ n: ChordNotation) -> String {
            switch self {
            case .major7: return n == .italian ? "7+" : "maj7"
            case .halfDim: return n == .italian ? "m7/5-" : "m7b5"
            case .aug: return n == .italian ? "5+" : "aug"
            default: return rawValue
            }
        }
    }

    init(root: Int, quality: Quality, bass: Int? = nil) {
        self.root = ((root % 12) + 12) % 12
        self.quality = quality
        self.bass = bass.map { (($0 % 12) + 12) % 12 }
        if self.bass == self.root { self.bass = nil }
    }

    var pitchClasses: [Int] { quality.intervals.map { ($0 + root) % 12 } }

    func transposed(_ semis: Int) -> Chord {
        Chord(root: root + semis, quality: quality, bass: bass.map { $0 + semis })
    }

    /// Semplifica a triade maggiore/minore.
    var triad: Chord { Chord(root: root, quality: quality.isMinor ? .minor : .major, bass: nil) }

    static let sharpEN = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    static let flatEN = ["C", "Db", "D", "Eb", "E", "F", "Gb", "G", "Ab", "A", "Bb", "B"]
    static let sharpIT = ["Do", "Do#", "Re", "Re#", "Mi", "Fa", "Fa#", "Sol", "Sol#", "La", "La#", "Si"]
    static let flatIT = ["Do", "Reb", "Re", "Mib", "Mi", "Fa", "Solb", "Sol", "Lab", "La", "Sib", "Si"]

    static func noteName(_ pc: Int, notation: ChordNotation, preferFlats: Bool) -> String {
        let i = ((pc % 12) + 12) % 12
        switch (notation, preferFlats) {
        case (.italian, false): return sharpIT[i]
        case (.italian, true): return flatIT[i]
        case (.english, false): return sharpEN[i]
        case (.english, true): return flatEN[i]
        }
    }

    /// Le note nere più comuni si scrivono con il bemolle (Sib, Mib, Lab) e il diesis per Do# e Fa#.
    static func defaultPrefersFlat(_ pc: Int) -> Bool { [3, 8, 10].contains(pc) }

    func name(_ notation: ChordNotation, preferFlats: Bool? = nil) -> String {
        let flats = preferFlats ?? Chord.defaultPrefersFlat(root)
        var s = Chord.noteName(root, notation: notation, preferFlats: flats) + quality.display(notation)
        if let b = bass { s += "/" + Chord.noteName(b, notation: notation, preferFlats: flats) }
        return s
    }

    /// Interpreta un accordo scritto in italiano o in inglese: "Lam", "Do#7", "Sib7+", "Am", "C/E", "F#m7b5".
    static func parse(_ text: String) -> Chord? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var main = s, bassPart: String?
        if let slash = s.firstIndex(of: "/"), s.distance(from: s.startIndex, to: slash) > 0 {
            let after = String(s[s.index(after: slash)...])
            // "m7/5-" è una qualità, non un basso.
            if parseRoot(after) != nil && !after.hasPrefix("5") {
                main = String(s[..<slash]); bassPart = after
            }
        }
        guard let parsedRoot = parseRoot(main) else { return nil }
        let root = parsedRoot.0
        let q = parseQuality(parsedRoot.1)
        guard let quality = q else { return nil }
        var bass: Int?
        if let bp = bassPart, let pb = parseRoot(bp) { bass = pb.0 }
        return Chord(root: root, quality: quality, bass: bass)
    }

    private static func parseRoot(_ s: String) -> (Int, String)? {
        let lower = s.lowercased()
        let it: [(String, Int)] = [("sol", 7), ("do", 0), ("re", 2), ("mi", 4), ("fa", 5), ("la", 9), ("si", 11)]
        var base: Int?
        var rest = Substring(s)
        for (n, v) in it where lower.hasPrefix(n) {
            base = v; rest = s.dropFirst(n.count); break
        }
        if base == nil, let f = s.first {
            let map: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11, "H": 11]
            if let v = map[Character(f.uppercased())], f.isUppercase || s.count <= 3 {
                base = v; rest = s.dropFirst()
            }
        }
        guard var r = base else { return nil }
        if rest.hasPrefix("#") || rest.hasPrefix("♯") { r += 1; rest = rest.dropFirst() }
        else if rest.hasPrefix("b") && !(rest.hasPrefix("b5")) || rest.hasPrefix("♭") {
            // "b" è bemolle solo subito dopo la nota (Sib, Bb).
            r -= 1; rest = rest.dropFirst()
        }
        return ((r + 12) % 12, String(rest))
    }

    private static func parseQuality(_ raw: String) -> Quality? {
        let q = raw.replacingOccurrences(of: " ", with: "")
        let table: [String: Quality] = [
            "": .major, "maj": .major, "M": .major,
            "m": .minor, "min": .minor, "-": .minor,
            "7": .seventh, "dom7": .seventh,
            "maj7": .major7, "7+": .major7, "M7": .major7, "Δ": .major7, "Δ7": .major7, "j7": .major7,
            "m7": .minor7, "min7": .minor7, "-7": .minor7,
            "sus4": .sus4, "sus": .sus4, "4": .sus4, "sus2": .sus2, "2": .sus2,
            "dim": .dim, "°": .dim, "o": .dim, "dim5": .dim,
            "m7b5": .halfDim, "m7/5-": .halfDim, "ø": .halfDim, "m7(b5)": .halfDim,
            "aug": .aug, "+": .aug, "5+": .aug, "+5": .aug,
            "6": .sixth, "m6": .minor6, "add9": .add9, "add2": .add9, "9": .ninth,
            "dim7": .dim7, "°7": .dim7, "o7": .dim7
        ]
        if let v = table[q] { return v }
        // Estensioni non riconosciute: tengo la base maggiore/minore.
        if q.hasPrefix("m") && !q.hasPrefix("maj") { return q.contains("7") ? .minor7 : .minor }
        if q.contains("7") { return .seventh }
        if q.allSatisfy({ $0.isNumber || "()#b+-".contains($0) }) { return .major }
        return nil
    }
}

/// Accordo con il suo istante nel brano (secondi a velocità originale).
struct ChordEvent: Codable, Hashable {
    var time: Double
    var chord: Chord?   // nil = N.C.
}

/// Riconoscimento della tonalità (profili di Krumhansl-Schmuckler, come nell'app originale).
enum KeyDetector {
    static let major: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func detect(_ pc: [Double]) -> (root: Int, minor: Bool) {
        func corr(_ prof: [Double], _ t: Int) -> Double {
            let mx = pc.reduce(0, +) / 12, my = prof.reduce(0, +) / 12
            var n = 0.0, dx = 0.0, dy = 0.0
            for i in 0..<12 {
                let x = pc[(i + t) % 12] - mx, y = prof[i] - my
                n += x * y; dx += x * x; dy += y * y
            }
            return n / max(1e-9, (dx * dy).squareRoot())
        }
        var best = (s: -2.0, t: 0, m: false)
        for t in 0..<12 {
            let a = corr(major, t), b = corr(minor, t)
            if a > best.s { best = (a, t, false) }
            if b > best.s { best = (b, t, true) }
        }
        return (best.t, best.m)
    }

    static func name(root: Int, minor: Bool, notation: ChordNotation) -> String {
        let n = Chord.noteName(root, notation: notation, preferFlats: Chord.defaultPrefersFlat(root) || [5].contains(root) && !minor)
        if notation == .italian { return n + (minor ? " minore" : " maggiore") }
        return n + (minor ? " minor" : " major")
    }
}
