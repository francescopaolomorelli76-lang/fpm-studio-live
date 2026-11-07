// Test della logica musicale (eseguibile anche fuori da Xcode).
import Foundation

func makeTestSong() -> Data {
    let ppq = 480, bar = ppq * 4
    var w = MIDIWriter(ppq: ppq)
    w.addTrack("Tempo", [.init(tick: 0, bytes: MIDIWriter.tempo(bpm: 100)), .init(tick: 0, bytes: MIDIWriter.meta(0x58, [4, 2, 24, 8]))])
    // Progressioni: strofa Lam-Fa-Do-Sol, ritornello Do-Sol-Lam-Fa.
    let verse: [(Int, Bool)] = [(9, true), (5, false), (0, false), (7, false)]
    let chorus: [(Int, Bool)] = [(0, false), (7, false), (9, true), (5, false)]
    // Forma: intro(2) V(8) C(8) V(8) C(8) Bridge(4) C(8) outro(2)
    var form: [(Int, Bool)] = [(0, false), (7, false)]
    var lyricBars: [Int: String] = [:]
    func addBlock(_ p: [(Int, Bool)], _ times: Int, _ words: [String]) {
        for i in 0..<(p.count * times) {
            lyricBars[form.count] = words[i % words.count]
            form.append(p[i % p.count])
        }
    }
    addBlock(verse, 2, ["cammino sola nella notte", "vedo stelle lontane", "il vento porta voce", "e io resto qui", "passa un treno senza nome", "chiudo gli occhi e poi", "sento il mondo che si muove", "piano dentro noi"])
    addBlock(chorus, 2, ["vola vola cuore mio", "sopra il mare blu", "canta canta amore", "non lasciarmi più"])
    addBlock(verse, 2, ["torna il giorno sulla strada", "luci accese in città", "ogni passo una promessa", "e il cuore lo sa", "porto addosso le parole", "scritte sulla sabbia", "come onde verso il sole", "senza rabbia"])
    addBlock(chorus, 2, ["vola vola cuore mio", "sopra il mare blu", "canta canta amore", "non lasciarmi più"])
    for (i, c) in [(2, false), (4, false), (11, false), (7, true)].enumerated() { lyricBars[form.count] = ["ma se il tempo cambia", "tutto quanto va", "dimmi dove andrai", "resterò con te"][i]; form.append(c) }
    addBlock(chorus, 2, ["vola vola cuore mio", "sopra il mare blu", "canta canta amore", "non lasciarmi più"])
    form += [(0, false), (0, false)]
    var pad: [MIDIWriter.TrackEvent] = [.init(tick: 0, bytes: [0xC1, 48])]
    var bass: [MIDIWriter.TrackEvent] = [.init(tick: 0, bytes: [0xC2, 33])]
    var mel: [MIDIWriter.TrackEvent] = [.init(tick: 0, bytes: [0xC3, 73])]
    var lyr: [MIDIWriter.TrackEvent] = []
    var lastWasLyric = false
    for (b, c) in form.enumerated() {
        let t = b * bar
        let iv = c.1 ? [0, 3, 7] : [0, 4, 7]
        for x in iv { pad += [.init(tick: t, bytes: [0x91, UInt8(60 + c.0 + x), 80]), .init(tick: t + bar, bytes: [0x81, UInt8(60 + c.0 + x), 0])] }
        bass += [.init(tick: t, bytes: [0x92, UInt8(36 + c.0), 90]), .init(tick: t + bar / 2, bytes: [0x82, UInt8(36 + c.0), 0])]
        bass += [.init(tick: t + bar / 2, bytes: [0x92, UInt8(43 + c.0), 90]), .init(tick: t + bar, bytes: [0x82, UInt8(43 + c.0), 0])]
        if let words = lyricBars[b] {
            let ws = words.split(separator: " ")
            for (k, wd) in ws.enumerated() {
                let tt = t + k * bar / ws.count
                var txt = String(wd) + " "
                if k == 0 && !lastWasLyric { txt = "\\" + txt } else if k == 0 { txt = "/" + txt }
                lyr.append(.init(tick: tt, bytes: MIDIWriter.text(0x01, txt)))
                let p = UInt8(67 + (k % 3) * 2 + c.0 % 3)
                mel += [.init(tick: tt, bytes: [0x93, p, 100]), .init(tick: tt + bar / ws.count - 10, bytes: [0x83, p, 0])]
            }
            lastWasLyric = true
            if (b - 2) % 4 == 3 { lastWasLyric = false }
        } else { lastWasLyric = false }
    }
    w.addTrack("Words", [.init(tick: 0, bytes: MIDIWriter.text(0x01, "@KMIDI KARAOKE FILE")), .init(tick: 0, bytes: MIDIWriter.text(0x01, "@TVola cuore"))] + lyr)
    w.addTrack("Archi", pad); w.addTrack("Basso", bass); w.addTrack("Melodia", mel)
    return w.data()
}

func runSelfTest() {
    let data = makeTestSong()
    let midi = try! MIDIFile(data: data)
    let lyrics = midi.karaokeLyrics()
    print("Durata \(String(format: "%.1f", midi.duration)) s, BPM \(midi.mainBPM), righe testo \(lyrics.lines.count), titolo \(lyrics.title ?? "-")")
    let an = ChordEngine.analyze(midi, lyrics: lyrics)
    print("Melodia ch \(an.melodyChannel ?? -1), bassi \(an.bassChannels), armonia \(an.harmonyChannels), tonalità \(KeyDetector.name(root: an.key.root, minor: an.key.minor, notation: .italian))")
    let evs = ChordEngine.events(an.regions, midi: midi)
    print("Accordi:", evs.prefix(12).map { $0.chord?.name(.italian) ?? "N.C." }.joined(separator: " "))
    let input = SongStructureAnalyzer.input(midi: midi, lyrics: lyrics, chords: evs, melodyChannel: an.melodyChannel)
    let secs = SongStructureAnalyzer.analyze(input)
    let barSec = midi.seconds(atTick: midi.ticksPerBar)
    print("Struttura:", secs.map { "\($0.title)[\(Int(($0.start / barSec).rounded()))-\(Int(($0.end / barSec).rounded()))]" }.joined(separator: " "))
    let piano = PianoArranger(midi: midi, regions: an.regions, sections: secs, options: PianoOptions(keepOriginalBass: true), bassChannels: an.bassChannels).arrange()
    let pm = try! MIDIFile(data: piano)
    print("Piano: \(pm.notes.filter { $0.channel == 0 }.count) note, range \(pm.notes.map { $0.pitch }.min()!)-\(pm.notes.map { $0.pitch }.max()!), basso \(pm.notes.filter { $0.channel != 0 }.count), durata \(String(format: "%.1f", pm.duration))")
    // Accordi dal piano generato = accordi originali?
    let check = ChordEngine.analyze(pm, lyrics: nil, melodyOverride: -1)
    let a = ChordEngine.events(an.regions, midi: midi).compactMap { $0.chord?.triad }
    let b = ChordEngine.events(check.regions, midi: pm).compactMap { $0.chord?.triad }
    print("Orig:", a.prefix(24).map { $0.name(.english) }.joined(separator: " ")); print("Piano:", b.prefix(24).map { $0.name(.english) }.joined(separator: " "))
    print("Accordi originali \(a.count), ricostruiti dal piano \(b.count), uguali nei primi 20: \(zip(a.prefix(20), b.prefix(20)).filter { $0 == $1 }.count)")
    // Editor testo
    var l2 = lyrics; l2.lines[0].syllables[0].chord = Chord.parse("Lam")
    let txt = l2.editorText(notation: .italian)
    let back = KaraokeLyrics.fromEditorText(txt, keeping: l2)
    print("Editor round-trip: righe \(back.lines.count)/\(l2.lines.count), tempi conservati \(back.lines[0].isSynced), accordo \(back.lines[0].syllables[0].chord?.name(.english) ?? "-")")
    for s in ["Lam", "Do#7", "Sib7+", "F#m7b5", "C/E", "Solsus4", "Bb", "La/Do#", "Mim7"] { print(s, "→", Chord.parse(s)?.name(.english) ?? "?", "/", Chord.parse(s)?.name(.italian) ?? "?") }
    try? piano.write(to: URL(fileURLWithPath: "/tmp/fpm_piano_test.mid"))
    try? data.write(to: URL(fileURLWithPath: "/tmp/fpm_song_test.kar"))
}

func runGeneratorTest() {
    var r = GeneratorRequest()
    r.title = "Prova AI"
    r.styles = [.pop]
    r.vocal = .guideMelody
    r.duration = 0
    r.lyrics = """
    Cammino piano nella sera
    e la città si accende già
    porto addosso una preghiera
    che nessuno ascolterà

    [Ritornello]
    Vola vola cuore mio
    sopra il mare e la realtà
    vola vola insieme a Dio
    dove il sole nascerà

    Passa il tempo sulle strade
    resta il segno di chi va

    [Ritornello]
    Vola vola cuore mio
    sopra il mare e la realtà
    vola vola insieme a Dio
    dove il sole nascerà
    """
    for st in [MusicStyle.pop, .pianoBallad, .jazz, .liscio, .dance] {
        r.styles = [st]; r.seed = 7
        let g = SongGenerator(req: r, reference: nil).generate()
        let m = try! MIDIFile(data: g.midi)
        let lyr = m.karaokeLyrics()
        print(st.label, "|", g.summary, "| tracce", m.usedChannels, "| note", m.notes.count, "| righe testo", lyr.lines.count, "|", g.sections.map { $0.title }.joined(separator: " "))
        if st == .pop {
            print("  accordi:", g.chords.prefix(10).map { $0.chord?.name(.italian) ?? "NC" }.joined(separator: " "))
            print("  riga 1:", g.lyrics.lines[0].syllables.map { $0.text }.joined(separator: "|"), String(format: "t0=%.2f", g.lyrics.lines[0].startTime))
            try? g.midi.write(to: URL(fileURLWithPath: "/tmp/fpm_ai_pop.mid"))
        }
    }
    var s = GeneratorRequest(); s.duration = 30; s.styles = [.rock]; s.negativeText = "no drums, archi"
    let g2 = SongGenerator(req: s, reference: nil).generate()
    print("Da zero 30s:", g2.summary, g2.sections.map { $0.title })
    s.duration = 180; s.styles = MusicStyle.fromText("cinematic, orchestral"); s.strangeness = 1
    let g3 = SongGenerator(req: s, reference: nil).generate()
    print("Da zero 3min:", g3.summary, g3.sections.map { $0.title })
    print(Syllabifier.split("cammino"), Syllabifier.split("preghiera"), Syllabifier.split("ascolterà"), Syllabifier.split("strade"), Syllabifier.split("nascerà"))
}

func runAdvancedTest() {
    let evs = [LiveEvent(time: 10, kind: .keyChange, value: 2), LiveEvent(time: 20, kind: .message, text: "Tutti insieme!"),
               LiveEvent(time: 30, kind: .clearMessage), LiveEvent(time: 40, kind: .keyChange, value: -1),
               LiveEvent(time: 45, kind: .pdfPage, value: 3), LiveEvent(time: 50, kind: .fadeOut, value: 4)]
    print("stato a 25:", EventTimeline.state(at: 25, events: evs))
    print("stato a 47:", EventTimeline.state(at: 47, events: evs))
    print("da eseguire 39..51:", EventTimeline.due(from: 39, to: 51, events: evs).map { $0.kind.rawValue })
    print("salto indietro:", EventTimeline.due(from: 51, to: 12, events: evs).count)
    // Sidecar vecchio senza campi nuovi
    let old = #"{"version":1,"lyricsOffset":0,"defaultTranspose":0,"defaultTempo":1}"#
    let sc = try! JSONDecoder().decode(SongSidecar.self, from: old.data(using: .utf8)!)
    print("sidecar vecchio ok, marker:", sc.markers as Any)
    for n in ["Do", "Lam", "Sol7", "Fa", "Sib", "Fa#m", "Mi", "Re", "Do#m7", "Lab7+"] {
        let c = Chord.parse(n)!
        let g = ChordDiagrams.guitar(c)
        print(n, g.frets.map { $0 < 0 ? "x" : String($0) }.joined(), "base", g.baseFret, "| piano", ChordDiagrams.piano(c).notes)
    }
}

func runLyricsFormatsTest() {
    // 1. Stile più diffuso: a capo all'INIZIO della sillaba ("\rNel"), testo nella traccia 2, rumore in altre tracce.
    var w = MIDIWriter(ppq: 480)
    w.addTrack("Tempo", [.init(tick: 0, bytes: MIDIWriter.tempo(bpm: 120)), .init(tick: 0, bytes: MIDIWriter.text(0x01, "Copyright 2020")),
                         .init(tick: 0, bytes: MIDIWriter.text(0x01, "Generated by Sequencer"))])
    let syl = ["Nel ", "blu ", "di", "pin", "to ", "di ", "blu", "\rFe", "li", "ce ", "di ", "sta", "re ", "las", "sù", "\r\nE ", "vo", "la", "vo ", "vo", "la", "vo"]
    var ev: [MIDIWriter.TrackEvent] = []
    for (i, s) in syl.enumerated() { ev.append(.init(tick: 480 + i * 240, bytes: MIDIWriter.text(0x05, s))) }
    w.addTrack("Lyrics", ev)
    w.addTrack("Note", [.init(tick: 0, bytes: MIDIWriter.text(0x01, "Verse")), .init(tick: 5000, bytes: MIDIWriter.text(0x01, "Chorus"))])
    let m = try! MIDIFile(data: w.data())
    let l = m.karaokeLyrics()
    print("MIDI \\r iniziale:", l.lines.map { $0.text }, "paragrafi:", l.lines.map { $0.endsParagraph })
    // 2. Nessun a capo: divisione automatica alle pause.
    var w2 = MIDIWriter(ppq: 480)
    var ev2: [MIDIWriter.TrackEvent] = []
    var t = 480
    for i in 0..<30 { ev2.append(.init(tick: t, bytes: MIDIWriter.text(0x05, "parola\(i) "))); t += (i % 8 == 7) ? 1600 : 240 }
    w2.addTrack("L", ev2)
    let l2 = try! MIDIFile(data: w2.data()).karaokeLyrics()
    print("MIDI senza a capo → righe:", l2.lines.count, l2.lines.map { $0.syllables.count })
    // 3. ID3 SYLT (UTF-8) in un finto MP3.
    func be32(_ v: Int) -> [UInt8] { [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
    var sylt: [UInt8] = [3] + Array("ita".utf8) + [2, 1, 0]
    for (i, s) in ["Ciao ", "a ", "tut", "ti", "\nSe", "con", "da ", "ri", "ga"].enumerated() { sylt += Array(s.utf8) + [0] + be32(1000 + i * 400) }
    var frame = Array("SYLT".utf8) + be32(sylt.count) + [0, 0] + sylt
    let size = frame.count
    var mp3: [UInt8] = Array("ID3".utf8) + [3, 0, 0, UInt8(size >> 21 & 127), UInt8(size >> 14 & 127), UInt8(size >> 7 & 127), UInt8(size & 127)] + frame
    mp3 += [0xFF, 0xFB, 0x90, 0x00]
    if let f = ID3Lyrics.parse(Data(mp3)) { print("ID3 SYLT:", f.source, f.lyrics.lines.map { $0.text }, f.lyrics.lines.first?.syllables.first?.time ?? -9) }
    else { print("ID3 SYLT: NON LETTO") }
    // 4. USLT con LRC dentro (v2.4).
    let lrc = "[00:01.00]Prima riga\n[00:04.50]Seconda riga"
    let uslt: [UInt8] = [3] + Array("ita".utf8) + [0] + Array(lrc.utf8)
    frame = Array("USLT".utf8) + [0, 0, UInt8(uslt.count >> 7 & 127), UInt8(uslt.count & 127)] + [0, 0] + uslt
    mp3 = Array("ID3".utf8) + [4, 0, 0, 0, 0, UInt8(frame.count >> 7 & 127), UInt8(frame.count & 127)] + frame
    if let f = ID3Lyrics.parse(Data(mp3)) { print("ID3 USLT:", f.source, f.lyrics.lines.map { "\($0.startTime) \($0.text)" }) }
    // 5. SRT
    let srt = LyricsSources.fromSRT("1\n00:00:01,000 --> 00:00:03,000\nCiao <i>mondo</i>\n\n2\n00:00:04,000 --> 00:00:06,500\nSeconda riga\n")
    print("SRT:", srt.lines.map { "\($0.startTime) \($0.text)" })
    // 6. CDG: palette + memory preset + un tile.
    func pkt(_ instr: UInt8, _ d: [UInt8]) -> [UInt8] { [9, instr, 0, 0] + d + [UInt8](repeating: 0, count: 16 - d.count) + [0, 0, 0, 0] }
    var cdg: [UInt8] = []
    cdg += pkt(30, [0, 0, 0x3C, 0x0F] + [UInt8](repeating: 0, count: 12))        // colore 0 nero, colore 1 bianco (r=15,g=15,b=15)
    cdg += pkt(1, [0, 0])                                                          // tutto colore 0
    cdg += pkt(6, [0, 1, 2, 5] + [UInt8](repeating: 0x3F, count: 12))           // tile pieno colore 1 a riga 2, colonna 5
    let dec = CDGDecoder(data: Data(cdg))
    dec.advance(to: 1)
    let rgba = dec.visibleRGBA()
    let px = { (x: Int, y: Int) -> UInt8 in rgba[(y * 288 + x) * 4] }
    print("CDG: pacchetti \(dec.packetCount), pixel tile (rosso)=\(px(5 * 6 - 6 + 2, 2 * 12 - 12 + 3)), fuori=\(px(0, 0)), inchiostro \(String(format: "%.4f", dec.inkRatio))")
}

func runCoverageTest() {
    // Archi SOLO nel ritornello; nella strofa c'è una chitarra che arpeggia e un pianoforte a note singole.
    let ppq = 480, bar = ppq * 4
    var w = MIDIWriter(ppq: ppq)
    w.addTrack("T", [.init(tick: 0, bytes: MIDIWriter.tempo(bpm: 100))])
    let prog: [(Int, Bool)] = [(9, true), (5, false), (0, false), (7, false)]
    var strings: [MIDIWriter.TrackEvent] = [.init(tick: 0, bytes: [0xC1, 48])]
    var guitar: [MIDIWriter.TrackEvent] = [.init(tick: 0, bytes: [0xC2, 25])]
    var bass: [MIDIWriter.TrackEvent] = [.init(tick: 0, bytes: [0xC3, 33])]
    var mel: [MIDIWriter.TrackEvent] = [.init(tick: 0, bytes: [0xC4, 73])]
    var drums: [MIDIWriter.TrackEvent] = []
    for b in 0..<32 {
        let c = prog[b % 4], t = b * bar + 2 * bar   // 2 battute di sola batteria all'inizio
        let iv = c.1 ? [0, 3, 7] : [0, 4, 7]
        let chorus = (b / 8) % 2 == 1
        if chorus { for x in iv { strings += [.init(tick: t, bytes: [0x91, UInt8(60 + c.0 + x), 80]), .init(tick: t + bar, bytes: [0x81, UInt8(60 + c.0 + x), 0])] } }
        else { for k in 0..<8 { let p = UInt8(48 + c.0 + iv[k % 3]); guitar += [.init(tick: t + k * ppq / 2, bytes: [0x92, p, 70]), .init(tick: t + k * ppq / 2 + ppq / 2, bytes: [0x82, p, 0])] } }
        bass += [.init(tick: t, bytes: [0x93, UInt8(36 + c.0), 90]), .init(tick: t + bar, bytes: [0x83, UInt8(36 + c.0), 0])]
        mel += [.init(tick: t, bytes: [0x94, UInt8(72 + c.0 % 5), 100]), .init(tick: t + ppq, bytes: [0x84, UInt8(72 + c.0 % 5), 0])]
    }
    for k in 0..<(34 * 4) { drums += [.init(tick: k * ppq, bytes: [0x99, 36, 100]), .init(tick: k * ppq + 60, bytes: [0x89, 36, 0])] }
    w.addTrack("Archi", strings); w.addTrack("Chitarra", guitar); w.addTrack("Basso", bass); w.addTrack("Melodia", mel); w.addTrack("Batteria", drums)
    let midi = try! MIDIFile(data: w.data())
    let an = ChordEngine.analyze(midi, lyrics: nil)
    let nc = an.regions.filter { $0.chord == nil && $0.startTick < midi.endTick - bar }.reduce(0) { $0 + $1.endTick - $1.startTick }
    print("Copertura: melodia ch\(an.melodyChannel ?? -1), battute senza accordo dentro il brano: \(Double(nc) / Double(bar))")
    print("Accordi strofa:", ChordEngine.events(an.regions, midi: midi).prefix(9).map { $0.chord?.name(.italian) ?? "NC" }.joined(separator: " "))
    let piano = try! MIDIFile(data: PianoArranger(midi: midi, regions: an.regions, sections: [], options: PianoOptions(), bassChannels: an.bassChannels).arrange())
    let bars = Set(piano.notes.map { $0.startTick / bar })
    print("Piano: prima nota battuta \(piano.notes.map { $0.startTick }.min()! / bar), battute coperte \(bars.count) su \(midi.endTick / bar)")
    var o = PianoOptions(); o.mode = .originalWithoutMelody
    let orig = try! MIDIFile(data: PianoArranger(midi: midi, regions: an.regions, sections: [], options: o, bassChannels: an.bassChannels, melodyChannel: an.melodyChannel).arrange())
    print("Originale senza melodia: canali \(orig.usedChannels), durata \(String(format: "%.1f", orig.duration)) vs \(String(format: "%.1f", midi.duration))")
    o.mode = .originalPlusPiano
    let plus = try! MIDIFile(data: PianoArranger(midi: midi, regions: an.regions, sections: [], options: o, bassChannels: an.bassChannels, melodyChannel: an.melodyChannel).arrange())
    print("Originale + piano: canali \(plus.usedChannels)")
}

func runFollowTest() {
    // Usa il brano di prova della copertura: confronto gli attacchi del piano con quelli della base originale.
    let ppq = 480, bar = ppq * 4
    var w = MIDIWriter(ppq: ppq)
    w.addTrack("T", [.init(tick: 0, bytes: MIDIWriter.tempo(bpm: 92)), .init(tick: bar * 6, bytes: MIDIWriter.tempo(bpm: 104))])
    var gtr: [MIDIWriter.TrackEvent] = [.init(tick: 0, bytes: [0xC1, 25])], bass: [MIDIWriter.TrackEvent] = [.init(tick: 0, bytes: [0xC2, 33])]
    let prog = [0, 9, 5, 7]
    for b in 0..<12 {
        let r = prog[b % 4], minor = r == 9
        // comping sincopato: colpi a 0, 1.5, 3 (in quarti)
        for off in [0, ppq * 3 / 2, ppq * 3] {
            for x in (minor ? [0, 3, 7] : [0, 4, 7]) { gtr += [.init(tick: b * bar + off, bytes: [0x91, UInt8(55 + (r + x) % 12), 80]), .init(tick: b * bar + off + ppq / 2, bytes: [0x81, UInt8(55 + (r + x) % 12), 0])] }
        }
        bass += [.init(tick: b * bar, bytes: [0x92, UInt8(36 + r), 90]), .init(tick: b * bar + ppq * 2 - 10, bytes: [0x82, UInt8(36 + r), 0]),
                 .init(tick: b * bar + ppq * 2, bytes: [0x92, UInt8(43 + r), 90]), .init(tick: b * bar + bar - 10, bytes: [0x82, UInt8(43 + r), 0])]
    }
    w.addTrack("Chitarra", gtr); w.addTrack("Basso", bass)
    let midi = try! MIDIFile(data: w.data())
    let an = ChordEngine.analyze(midi, lyrics: nil)
    let out = try! MIDIFile(data: PianoArranger(midi: midi, regions: an.regions, sections: [], options: PianoOptions(), bassChannels: an.bassChannels).arrange())
    let origOn = Set(midi.notes.map { $0.startTick })
    let pianoOn = Set(out.notes.filter { $0.channel == 0 }.map { $0.startTick / 4 * 4 })
    let match = pianoOn.filter { p in origOn.contains { abs($0 - p) <= 8 } }.count
    print("Segue l'originale: attacchi piano \(pianoOn.count), coincidenti con l'originale \(match); durata \(String(format: "%.2f", out.duration)) vs \(String(format: "%.2f", midi.duration)); tempi \(out.tempoMap.count) vs \(midi.tempoMap.count)")
}
