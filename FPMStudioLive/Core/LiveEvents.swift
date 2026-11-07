import Foundation

/// Marker di un brano (fino a 10): salto, cue, loop con numero di ripetizioni.
struct SongMarker: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var time: Double                 // secondi del brano originale
    var loopEnd: Double? = nil       // se presente: loop time…loopEnd
    var repeats: Int = 0             // 0 = loop infinito finché attivo

    static let maxCount = 10
}

/// Eventi temporizzati sulla timeline del brano (sezione F del capitolato).
struct LiveEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case keyChange, tempoChange, songVolume, fadeOut, message, clearMessage
        case jumpToMarker, pdfPage, metronomeOn, metronomeOff, playSample, nextSong
        var id: String { rawValue }
        var label: String {
            switch self {
            case .keyChange: return "KEY CHANGE (tono)"
            case .tempoChange: return "TEMPO CHANGE (%)"
            case .songVolume: return "SONG VOLUME"
            case .fadeOut: return "FADE OUT (secondi)"
            case .message: return "MESSAGGIO a schermo"
            case .clearMessage: return "TOGLI MESSAGGIO"
            case .jumpToMarker: return "SALTA A MARKER"
            case .pdfPage: return "PDF PAGNUM"
            case .metronomeOn: return "METRONOMO ON"
            case .metronomeOff: return "METRONOMO OFF"
            case .playSample: return "CUSTOM SAMPLE (slot)"
            case .nextSong: return "START MIX (brano successivo)"
            }
        }
        var usesValue: Bool { [.keyChange, .tempoChange, .songVolume, .fadeOut, .pdfPage, .playSample].contains(self) }
        var usesText: Bool { [.message, .jumpToMarker].contains(self) }
        /// Eventi "di stato": dopo un salto vengono ricalcolati, non rieseguiti.
        var isState: Bool { [.keyChange, .tempoChange, .songVolume, .message, .clearMessage, .pdfPage, .metronomeOn, .metronomeOff].contains(self) }
    }

    var id = UUID()
    var time: Double
    var kind: Kind
    var value: Double = 0
    var text: String = ""
    var enabled = true
}

/// Logica pura della timeline: stato dopo un salto e eventi da eseguire in un intervallo.
enum EventTimeline {
    struct State: Equatable {
        var transpose: Int?
        var tempo: Double?
        var volume: Double?
        var message: String?
        var pdfPage: Int?
        var metronome: Bool?
    }

    /// Stato risultante da tutti gli eventi di stato fino all'istante t (incluso).
    /// Così dopo seek o loop il risultato è deterministico e nessun evento viene eseguito due volte.
    static func state(at t: Double, events: [LiveEvent]) -> State {
        var s = State()
        for e in events.sorted(by: { $0.time < $1.time }) where e.enabled && e.time <= t && e.kind.isState {
            switch e.kind {
            case .keyChange: s.transpose = Int(e.value.rounded())
            case .tempoChange: s.tempo = e.value / 100
            case .songVolume: s.volume = e.value / 100
            case .message: s.message = e.text
            case .clearMessage: s.message = nil
            case .pdfPage: s.pdfPage = Int(e.value.rounded())
            case .metronomeOn: s.metronome = true
            case .metronomeOff: s.metronome = false
            default: break
            }
        }
        return s
    }

    /// Eventi con tempo in (from, to]. Se `to < from` (salto indietro/loop) non restituisce nulla:
    /// in quel caso si usa `state(at:)`.
    static func due(from: Double, to: Double, events: [LiveEvent]) -> [LiveEvent] {
        guard to >= from else { return [] }
        return events.filter { $0.enabled && $0.time > from && $0.time <= to }.sorted { $0.time < $1.time }
    }
}

/// Diteggiature per il Chord Bar: chitarra (forme E e A mobili + accordi aperti) e pianoforte.
enum ChordDiagrams {
    /// Tasti per corde Mi grave → Mi acuto; -1 = corda non suonata.
    static func guitar(_ c: Chord) -> (frets: [Int], baseFret: Int) {
        let opens: [String: [Int]] = [
            "0:": [-1, 3, 2, 0, 1, 0], "7:": [3, 2, 0, 0, 0, 3], "2:": [-1, -1, 0, 2, 3, 2], "2:m": [-1, -1, 0, 2, 3, 1],
            "2:7": [-1, -1, 0, 2, 1, 2], "0:7": [-1, 3, 2, 3, 1, 0], "7:7": [3, 2, 0, 0, 0, 1], "0:maj7": [-1, 3, 2, 0, 0, 0],
            "5:maj7": [-1, -1, 3, 2, 1, 0], "4:": [0, 2, 2, 1, 0, 0], "4:m": [0, 2, 2, 0, 0, 0], "4:7": [0, 2, 0, 1, 0, 0],
            "4:m7": [0, 2, 0, 0, 0, 0], "9:": [-1, 0, 2, 2, 2, 0], "9:m": [-1, 0, 2, 2, 1, 0], "9:7": [-1, 0, 2, 0, 2, 0],
            "9:m7": [-1, 0, 2, 0, 1, 0], "2:sus4": [-1, -1, 0, 2, 3, 3], "9:sus4": [-1, 0, 2, 2, 3, 0], "4:sus4": [0, 2, 2, 2, 0, 0]
        ]
        if c.bass == nil, let o = opens["\(c.root):\(c.quality.rawValue)"] { return (o, 1) }
        let eForm: [Chord.Quality: [Int]] = [
            .major: [0, 2, 2, 1, 0, 0], .minor: [0, 2, 2, 0, 0, 0], .seventh: [0, 2, 0, 1, 0, 0], .minor7: [0, 2, 0, 0, 0, 0],
            .major7: [0, -1, 1, 1, 0, -1], .sus4: [0, 2, 2, 2, 0, 0], .sixth: [0, -1, -1, 1, 2, 0], .minor6: [0, -1, -1, 0, 2, 0]
        ]
        let aForm: [Chord.Quality: [Int]] = [
            .major: [-1, 0, 2, 2, 2, 0], .minor: [-1, 0, 2, 2, 1, 0], .seventh: [-1, 0, 2, 0, 2, 0], .minor7: [-1, 0, 2, 0, 1, 0],
            .major7: [-1, 0, 2, 1, 2, 0], .sus4: [-1, 0, 2, 2, 3, 0], .sus2: [-1, 0, 2, 2, 0, 0], .dim: [-1, 0, 1, 2, 1, -1],
            .halfDim: [-1, 0, 1, 0, 1, -1], .aug: [-1, 0, 3, 2, 2, -1], .sixth: [-1, 0, 2, 2, 2, 2], .minor6: [-1, 0, 2, 2, 1, 2],
            .add9: [-1, 0, 2, 4, 2, 0], .ninth: [-1, 0, 2, 0, 2, 2], .dim7: [-1, 0, 1, 2, 1, 2]
        ]
        let fe = (c.root - 4 + 12) % 12, fa = (c.root - 9 + 12) % 12
        var options: [(Int, [Int])] = []
        if let s = eForm[c.quality] { options.append((fe, s)) }
        if let s = aForm[c.quality] { options.append((fa, s)) }
        if options.isEmpty { options = [(fa, aForm[.major]!)] }
        let best = options.min { $0.0 < $1.0 }!
        let frets = best.1.map { $0 < 0 ? -1 : $0 + best.0 }
        let used = frets.filter { $0 > 0 }
        return (frets, max(1, used.min() ?? 1))
    }

    /// Note MIDI per il disegno sulla tastiera (basso + accordo).
    static func piano(_ c: Chord) -> (bass: Int, notes: [Int]) {
        let bass = 48 + (c.bass ?? c.root)
        let notes = PianoArranger.voicing(for: c, previous: [60, 64, 67], rich: false, low: 57, high: 76)
        return (bass, notes)
    }
}
