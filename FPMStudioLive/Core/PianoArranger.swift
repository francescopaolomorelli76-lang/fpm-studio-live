import Foundation

enum PianoStyle: String, CaseIterable, Identifiable, Codable {
    case automatic, ballad, pop, arpeggio, sustained
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatico (per sezione)"
        case .ballad: return "Ballata"
        case .pop: return "Pop ritmico"
        case .arpeggio: return "Arpeggiato"
        case .sustained: return "Accordi tenuti"
        }
    }
}

struct PianoOptions: Codable, Equatable {
    var style: PianoStyle = .automatic
    var program: Int = 0                // 0 Gran coda, 1 Brillante, 4 Rhodes
    var simplifyToTriads: Bool = false
    var keepOriginalBass: Bool = false
    var keepOriginalDrums: Bool = false
    var humanize: Bool = true
    var finalRitardando: Bool = true
    var dynamics: Double = 1.0          // 0.6 ... 1.3
}

/// Genera un accompagnamento pianistico professionale a due mani SOLO dagli accordi
/// (nessuna melodia), rispettando armonia, metrica, tempi e struttura del brano originale.
///
/// Rispetto ai blocchi di accordi dell'app originale:
/// - condotta delle voci (ogni accordo sceglie il rivolto più vicino al precedente);
/// - mano sinistra con fondamentale/rivolto e quinta, ottave nei ritornelli;
/// - figure diverse per INTRO / VERSE / CHORUS / BRIDGE / OUTRO;
/// - pedale di risonanza cambiato a ogni accordo, dinamiche per sezione, umanizzazione;
/// - rallentando e accordo finale tenuto.
struct PianoArranger {
    let midi: MIDIFile
    let regions: [ChordRegion]
    let sections: [SongSection]
    let options: PianoOptions
    let bassChannels: Set<Int>

    static let pianoChannel = 0

    private struct Rand {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
        }
        mutating func range(_ a: Int, _ b: Int) -> Int { a + Int(next() * Double(b - a + 1)).clamped(0, b - a) }
    }

    func arrange() -> Data {
        var w = MIDIWriter(ppq: midi.ppq)
        var conductor = midi.conductorEvents()
        if options.finalRitardando { conductor += ritardando() }
        w.addTrack("FPM Studio Live - Tempo", conductor)
        w.addTrack("Pianoforte - accompagnamento", pianoEvents())
        if options.keepOriginalBass && !bassChannels.isEmpty {
            // Il basso va su un canale libero diverso dal piano.
            var remap: [Int: Int] = [:]
            for b in bassChannels { remap[b] = b == PianoArranger.pianoChannel ? 1 : b }
            w.addTrack("Basso originale", midi.channelEvents(bassChannels, remapTo: remap))
        }
        if options.keepOriginalDrums && midi.usedChannels.contains(9) {
            w.addTrack("Batteria originale", midi.channelEvents([9]))
        }
        return w.data()
    }

    // MARK: - Piano

    private func sectionKind(atTick t: Int) -> SectionKind {
        let s = midi.seconds(atTick: t)
        return sections.last(where: { $0.start <= s + 0.01 })?.kind ?? .verse
    }

    private func style(for kind: SectionKind) -> PianoStyle {
        if options.style != .automatic { return options.style }
        switch kind {
        case .intro, .outro: return .arpeggio
        case .verse: return .ballad
        case .preChorus: return .ballad
        case .chorus, .instrumental: return .pop
        case .bridge: return .sustained
        }
    }

    private func dynamic(for kind: SectionKind) -> Double {
        let base: Double
        switch kind {
        case .intro: base = 62
        case .verse: base = 68
        case .preChorus: base = 76
        case .chorus: base = 90
        case .bridge: base = 74
        case .instrumental: base = 84
        case .outro: base = 60
        }
        return base * options.dynamics
    }

    private func pianoEvents() -> [MIDIWriter.TrackEvent] {
        let ch = UInt8(PianoArranger.pianoChannel)
        var ev: [MIDIWriter.TrackEvent] = [
            .init(tick: 0, bytes: [0xB0 | ch, 0, 0]),
            .init(tick: 0, bytes: [0xB0 | ch, 32, 0]),
            .init(tick: 0, bytes: [0xC0 | ch, UInt8(options.program.clamped(0, 127))]),
            .init(tick: 0, bytes: [0xB0 | ch, 7, 110]),
            .init(tick: 0, bytes: [0xB0 | ch, 10, 64]),
            .init(tick: 0, bytes: [0xB0 | ch, 91, 52]),
            .init(tick: 0, bytes: [0xB0 | ch, 93, 0])
        ]
        var rng = Rand(state: 0x5EED_F00D)
        let ppq = midi.ppq
        let sig = midi.mainTimeSignature
        let beat = midi.ticksPerBeat
        let compound = sig.den == 8 && sig.num % 3 == 0 && sig.num >= 6
        let pulse = compound ? beat * 3 : beat               // pulsazione percepita
        let bar = midi.ticksPerBar
        let eighth = compound ? beat : max(1, beat / 2)

        // Accordi validi (almeno mezza pulsazione), eventualmente semplificati.
        var chords: [(start: Int, end: Int, chord: Chord)] = []
        for r in regions {
            guard var c = r.chord, r.endTick - r.startTick >= max(1, beat / 2) else { continue }
            if options.simplifyToTriads { c = c.triad }
            if let last = chords.last, last.end >= r.startTick - beat / 4, last.chord == c {
                chords[chords.count - 1].end = r.endTick
            } else {
                chords.append((r.startTick, r.endTick, c))
            }
        }
        guard !chords.isEmpty else { return ev }
        // Riempie i buchi brevi prolungando l'accordo precedente (suono legato).
        for i in 0..<(chords.count - 1) where chords[i + 1].start - chords[i].end <= bar {
            chords[i].end = chords[i + 1].start
        }

        var prevVoicing: [Int] = [60, 64, 67]
        func note(_ t: Int, _ dur: Int, _ p: Int, _ v: Double) {
            let pitch = UInt8(p.clamped(21, 108))
            let vel = UInt8(Int(v.rounded()).clamped(1, 127))
            ev.append(.init(tick: max(0, t), bytes: [0x90 | ch, pitch, vel]))
            ev.append(.init(tick: max(0, t) + max(1, dur), bytes: [0x80 | ch, pitch, 0]))
        }
        func human(_ t: Int, onBeat: Bool) -> Int {
            guard options.humanize, !onBeat else { return t }
            return t + rng.range(-ppq / 96, ppq / 96)
        }
        func vel(_ base: Double, accent: Double) -> Double {
            base * accent + (options.humanize ? Double(rng.range(-5, 5)) : 0)
        }

        for (ci, item) in chords.enumerated() {
            let c = item.chord
            let start = item.start, end = item.end
            let kind = sectionKind(atTick: start)
            let st = style(for: kind)
            let dyn = dynamic(for: kind)
            let rh = PianoArranger.voicing(for: c, previous: prevVoicing, rich: st == .sustained || kind == .bridge)
            prevVoicing = rh
            let bassPc = c.bass ?? c.root
            var bassNote = 36 + bassPc
            if bassNote > 47 { bassNote -= 12 }
            if bassNote < 33 { bassNote += 12 }
            let fifth = bassNote + ((c.root + c.quality.intervals[min(2, c.quality.intervals.count - 1)] - bassPc + 12) % 12)
            let octaves = kind == .chorus || kind == .instrumental
            // Raddoppio d'ottava della sinistra: mai sotto il Mi1.
            let lowOctave = bassNote - 12 >= 28 ? bassNote - 12 : bassNote + 12

            // Pedale: rilascio e ripresa a ogni cambio d'accordo.
            ev.append(.init(tick: max(0, start - 2), bytes: [0xB0 | ch, 64, 0]))
            ev.append(.init(tick: start + max(4, ppq / 24), bytes: [0xB0 | ch, 64, 120]))

            let isLast = ci == chords.count - 1
            if isLast {
                // Accordo finale: arpeggio rapido dal basso e tenuta.
                let hold = max(end - start, bar * 2)
                note(start, hold, lowOctave, dyn * 0.85)
                note(start, hold, bassNote, dyn * 0.8)
                for (k, p) in rh.enumerated() { note(start + k * max(1, ppq / 16), hold, p, dyn * 0.75) }
                // Fondamentale in alto per chiudere.
                var top = (rh.last ?? 72) + 1
                while top % 12 != c.root { top += 1 }
                note(start + rh.count * max(1, ppq / 16), hold, top, dyn * 0.6)
                ev.append(.init(tick: start + hold + ppq, bytes: [0xB0 | ch, 64, 0]))
                continue
            }

            // Punti della griglia che cadono nell'accordo (allineati alla battuta).
            var t = (start / eighth) * eighth
            if t < start { t += eighth }
            var firstHit = true
            while t < end {
                let posInBar = t % bar
                let isDownbeat = posInBar == 0
                let isPulse = posInBar % pulse == 0
                let accent = isDownbeat ? 1.08 : (isPulse ? 1.0 : 0.86)
                let remaining = end - t
                let onBeat = isPulse
                let tt = human(t, onBeat: onBeat)
                // Il primo colpo cade sempre sul cambio d'accordo, anche se fuori griglia.
                let hitTick = firstHit ? start : tt
                switch st {
                case .sustained:
                    if firstHit || isDownbeat {
                        let dur = min(remaining + (firstHit ? t - start : 0), bar)
                        note(hitTick, dur, bassNote, vel(dyn, accent: 0.95))
                        if octaves { note(hitTick, dur, lowOctave, vel(dyn, accent: 0.8)) }
                        for (k, p) in rh.enumerated() { note(hitTick + (options.humanize ? k * 3 : 0), dur, p, vel(dyn, accent: 0.82)) }
                    } else if posInBar == pulse * (sig.num / 2) && !compound && sig.num >= 4 {
                        note(tt, min(remaining, bar / 2), fifth, vel(dyn, accent: 0.7))
                    }
                case .arpeggio, .ballad:
                    // Mano sinistra: basso sul battere, quinta a metà battuta.
                    if firstHit || isDownbeat {
                        note(hitTick, min(remaining, bar / 2 + eighth), bassNote, vel(dyn, accent: accent))
                        if octaves { note(hitTick, min(remaining, bar / 2), lowOctave, vel(dyn, accent: 0.75)) }
                    } else if !compound && sig.num >= 4 && posInBar == pulse * (sig.num / 2) {
                        note(tt, min(remaining, bar / 2), fifth, vel(dyn, accent: 0.8))
                    } else if compound && posInBar == bar / 2 {
                        note(tt, min(remaining, bar / 2), fifth, vel(dyn, accent: 0.8))
                    }
                    // Mano destra: arpeggio a crome (ballata = più morbido, con la nota alta ripetuta).
                    let stepIndex = (posInBar / eighth)
                    let pattern: [Int] = st == .ballad ? [0, 1, 2, 1, 2, 1, 2, 1] : [0, 1, 2, 3, 2, 1, 2, 1]
                    let idx = pattern[stepIndex % pattern.count] % max(1, rh.count)
                    if !rh.isEmpty {
                        let p = rh[min(idx, rh.count - 1)]
                        let dur = min(remaining, eighth * 2)
                        note(firstHit ? start : tt, dur, p, vel(dyn, accent: accent * (st == .ballad ? 0.78 : 0.82)))
                    }
                case .pop, .automatic:
                    // Mano sinistra: ottave su 1 e 3, anticipo sul "e" del 4 nei ritornelli.
                    if firstHit || isDownbeat {
                        note(hitTick, min(remaining, pulse * 2 - eighth / 2), bassNote, vel(dyn, accent: 1.05))
                        if octaves { note(hitTick, min(remaining, pulse * 2 - eighth / 2), lowOctave, vel(dyn, accent: 0.9)) }
                    } else if !compound && sig.num >= 4 && posInBar == pulse * 2 {
                        note(tt, min(remaining, pulse * 2 - eighth / 2), bassNote, vel(dyn, accent: 0.95))
                        if octaves { note(tt, min(remaining, pulse), lowOctave, vel(dyn, accent: 0.8)) }
                    } else if sig.num == 3 && !compound && isPulse {
                        // Valzer: accordo sui tempi deboli.
                        for p in rh { note(tt, min(remaining, pulse - eighth / 2), p, vel(dyn, accent: 0.72)) }
                    }
                    // Mano destra: figura sincopata 3+3+2 (colpi su 1, 2e, 4) in 4/4.
                    let eighthIndex = posInBar / eighth
                    let hits: Set<Int> = sig.num >= 4 && !compound ? [0, 3, 6] : (compound ? [0, 3] : [])
                    if firstHit || hits.contains(eighthIndex % 8) {
                        let len = eighthIndex % 8 == 6 ? eighth * 2 : eighth * 3
                        for (k, p) in rh.enumerated() {
                            note((firstHit ? start : tt) + (options.humanize ? k * 2 : 0), min(remaining, len - eighth / 4), p,
                                 vel(dyn, accent: (isDownbeat ? 1.0 : 0.88)))
                        }
                    }
                }
                firstHit = false
                t += eighth
            }
        }
        return ev
    }

    /// Sceglie il rivolto più vicino al precedente (condotta delle voci) tra Sol3 e Sol5.
    static func voicing(for c: Chord, previous: [Int], rich: Bool, low: Int = 53, high: Int = 79) -> [Int] {
        var pcs = c.quality.intervals.map { ($0 + c.root) % 12 }
        // Con quattro note: tolgo la quinta se c'è la settima (suono più pulito).
        if pcs.count >= 4 {
            let fifth = (c.root + 7) % 12
            if !rich, let i = pcs.firstIndex(of: fifth), c.quality != .aug, c.quality != .dim7 { pcs.remove(at: i) }
            if pcs.count > 4 { pcs = Array(pcs.prefix(4)) }
        }
        if rich && pcs.count == 3 && !c.quality.isMinor && c.quality == .major { pcs.append((c.root + 2) % 12) } // add9 nel ponte
        if rich && pcs.count == 3 && c.quality == .minor { pcs.append((c.root + 10) % 12) } // m7 nel ponte
        let uniq = Array(Set(pcs))
        var best: [Int] = []
        var bestCost = Double.infinity
        let prevCenter = Double(previous.reduce(0, +)) / Double(max(1, previous.count))
        for bottom in low...(high - 11) {
            guard uniq.contains(bottom % 12) else { continue }
            var v = [bottom]
            var remaining = uniq.filter { $0 != bottom % 12 }
            var cur = bottom
            while !remaining.isEmpty {
                // Prossima nota dell'accordo sopra quella corrente.
                var nextP = cur + 1
                while !remaining.contains(nextP % 12) { nextP += 1 }
                remaining.removeAll { $0 == nextP % 12 }
                v.append(nextP); cur = nextP
            }
            guard v.last! <= high else { continue }
            let center = Double(v.reduce(0, +)) / Double(v.count)
            var cost = abs(center - prevCenter) * 1.2 + abs(center - Double(low + high) / 2) * 0.35
            // Movimento delle singole voci.
            let pv = previous.sorted()
            for (i, p) in v.enumerated() where i < pv.count { cost += Double(abs(p - pv[i])) * 0.25 }
            if cost < bestCost { bestCost = cost; best = v }
        }
        return best.isEmpty ? uniq.map { 60 + $0 }.sorted() : best
    }

    /// Rallentando nelle ultime due battute.
    private func ritardando() -> [MIDIWriter.TrackEvent] {
        guard let lastChord = regions.last(where: { $0.chord != nil }) else { return [] }
        let bar = midi.ticksPerBar
        let end = lastChord.startTick
        let start = max(0, end - bar * 2)
        let baseBPM = 60_000_000.0 / Double(midi.tempoMap.last(where: { $0.tick <= start })?.usPerQuarter ?? 500_000)
        var out: [MIDIWriter.TrackEvent] = []
        let steps = 8
        for i in 0...steps {
            let t = start + (end - start) * i / steps
            let f = 1 - 0.28 * Double(i) / Double(steps)
            out.append(.init(tick: t, bytes: MIDIWriter.tempo(bpm: baseBPM * f)))
        }
        return out
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { min(max(self, lo), hi) }
}
