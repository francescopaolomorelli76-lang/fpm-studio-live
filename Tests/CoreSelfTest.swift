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
