import Foundation
import AVFoundation
import SwiftUI

struct ChannelStrip: Identifiable, Hashable {
    var id: Int { channel }
    var channel: Int
    var name: String
    var program: Int
    var muted = false
    var solo = false
    var gain: Double = 1
    var isMelody = false
}

/// Posizione di riproduzione, separata per non ridisegnare tutta la finestra 30 volte al secondo.
final class PlaybackClock: ObservableObject {
    @Published var position: Double = 0
    /// Fotogramma CD+G corrente (aggiornato solo quando cambia).
    @Published var cdgImage: CGImage?
}

/// Lettore karaoke: basi MIDI/KAR (SoundFont), MP3 e video, con testo, accordi, tono, tempo e mixer.
final class KaraokePlayer: ObservableObject {
    @Published private(set) var item: LibraryItem?
    @Published private(set) var kind: SongKind?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var transpose = 0 { didSet { applyTransposeTempo() } }
    @Published var tempo = 1.0 { didSet { applyTransposeTempo() } }
    @Published var lyrics = KaraokeLyrics()
    @Published var chords: [ChordEvent] = []
    @Published var sections: [SongSection] = []
    @Published var lyricsOffset = 0.0
    @Published private(set) var channels: [ChannelStrip] = []
    @Published private(set) var keyName = ""
    @Published private(set) var bpm: Double?
    @Published private(set) var analyzing = false
    @Published var status = ""
    @Published private(set) var nextUpTitle: String?
    @Published private(set) var countdownToNext: Double?
    @Published private(set) var videoPlayer: AVPlayer?
    @Published private(set) var midi: MIDIFile?
    @Published private(set) var melodyChannel: Int?
    @Published private(set) var cdg: CDGDecoder?
    @Published private(set) var lyricsSource = ""

    // Funzioni avanzate: marker, loop, eventi, leggio, metronomo, volume brano.
    @Published var markers: [SongMarker] = []
    @Published var events: [LiveEvent] = []
    @Published var activeLoop: UUID?
    @Published var loopRemaining = 0
    @Published var banner: String?
    @Published var documentURL: URL?
    @Published var pdfPage = 1
    @Published var metronome = false { didSet { hub.sequencer.metronome = metronome } }
    @Published var precount = false
    @Published var songVolume = 1.0 { didSet { hub.karaokeMixer.outputVolume = Float(songVolume) } }
    @Published private(set) var bassChannels: Set<Int> = []
    var lastEventTime = 0.0
    var fadeTimer: Timer?
    /// Chiamato dagli eventi CUSTOM SAMPLE (slot 1…100).
    var onPlaySample: ((Int) -> Void)?

    weak var library: Library?
    let clock = PlaybackClock()
    var position: Double {
        get { clock.position }
        set { if abs(clock.position - newValue) > 0.0005 { clock.position = newValue } }
    }
    private let hub = AudioHub.shared
    private let fileAudio = AudioFilePlayer()
    private var timer: Timer?
    private var videoUsesOwnAudio = false
    private var advanceWork: DispatchWorkItem?
    private let settings = AppSettings.shared

    init() {
        hub.start()
        _ = hub.loadSoundBank(path: settings.effectiveSoundFontPath)
        if !settings.synthPluginID.isEmpty { usePlugin(id: settings.synthPluginID, name: settings.synthPluginName) }
        hub.synthReverb.wetDryMix = Float(settings.synthReverb)
        AudioHub.configureSynthEQ(hub.synthEQ, enabled: settings.synthEQ)
        hub.sequencer.onEnd = { [weak self] in self?.songEnded() }
        fileAudio.onEnd = { [weak self] in self?.songEnded() }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    /// Tempo del testo (secondi del brano originale), con la correzione di sincronia.
    var lyricsTime: Double { position + lyricsOffset }

    // MARK: Caricamento

    func load(_ item: LibraryItem, autoplay: Bool = false) {
        stop()
        advanceWork?.cancel(); countdownToNext = nil
        self.item = item
        kind = item.kind
        status = ""
        lyrics = KaraokeLyrics(); chords = []; sections = []; channels = []; keyName = ""; bpm = nil
        videoPlayer = nil; midi = nil; melodyChannel = nil
        cdg = nil; clock.cdgImage = nil; lyricsSource = ""
        let sidecar = SongSidecar.load(for: item.url)
        loadAdvanced(sidecar, for: item.url)
        lyricsOffset = sidecar?.lyricsOffset ?? 0
        do {
            switch item.kind {
            case .midi:
                let m = try MIDIFile(url: item.url)
                midi = m
                hub.sequencer.load(m)
                duration = m.duration
                bpm = m.mainBPM
                if let l = sidecar?.lyrics, !l.isEmpty { lyrics = Self.repaired(l); lyricsSource = "testo salvato in FPM Studio Live" }
                else {
                    lyrics = m.karaokeLyrics()
                    lyricsSource = lyrics.isEmpty ? "" : "testo del file MIDI/KAR"
                    if lyrics.isEmpty, let f = LyricsSources.find(for: item.url) { lyrics = f.lyrics; lyricsSource = f.source }
                }
                if lyrics.title == nil { lyrics.title = item.title }
                let an = ChordEngine.analyze(m, lyrics: lyrics, melodyOverride: sidecar?.melodyChannel)
                melodyChannel = an.melodyChannel
                bassChannels = an.bassChannels
                let embedded = m.embeddedChords()   // accordi scritti dal produttore (basi M-Live)
                chords = sidecar?.chords ?? (!embedded.isEmpty ? embedded : (lyrics.chordEvents.isEmpty ? ChordEngine.events(an.regions, midi: m) : lyrics.chordEvents))
                keyName = KeyDetector.name(root: an.key.root, minor: an.key.minor, notation: settings.notation)
                sections = sidecar?.sections ?? SongStructureAnalyzer.analyze(
                    SongStructureAnalyzer.input(midi: m, lyrics: lyrics, chords: chords, melodyChannel: an.melodyChannel))
                // Nome di ogni canale: il nome della sua traccia solo se è davvero sua (formato 1, traccia con un solo
                // canale, nome diverso dal titolo); altrimenti lo strumento General MIDI. Mai il titolo del brano.
                let titleKeys = Set([m.title, lyrics.title, item.title].compactMap { $0?.lowercased().trimmingCharacters(in: .whitespaces) })
                channels = m.usedChannels.map { ch in
                    let prog = m.programs[ch] ?? 0
                    var trackName = ""
                    if m.format == 1, let tr = m.notes.first(where: { $0.channel == ch })?.track,
                       Set(m.notes.filter { $0.track == tr }.map { $0.channel }).count == 1,
                       let n = m.trackNames[tr]?.trimmingCharacters(in: .whitespaces), !n.isEmpty,
                       !titleKeys.contains(n.lowercased()), n.count <= 24 {
                        trackName = n
                    }
                    let gm = ch == 9 ? "Batteria" : GM.name(prog)
                    let name = trackName.isEmpty || trackName.lowercased() == gm.lowercased() ? gm : "\(trackName) · \(gm)"
                    return ChannelStrip(channel: ch, name: name, program: prog, isMelody: ch == an.melodyChannel)
                }
            case .audio, .video:
                let media = try (item.kind == .video ? MediaResolver.Media(audio: item.url, cdg: nil) : MediaResolver.resolve(item.url))
                if let c = media.cdg, let d = try? Data(contentsOf: c) {
                    cdg = CDGDecoder(data: d)
                    clock.cdgImage = nil
                }
                if item.kind == .video {
                    let p = AVPlayer(url: item.url)
                    videoPlayer = p
                    do {
                        try fileAudio.load(item.url)
                        p.isMuted = true
                        videoUsesOwnAudio = false
                    } catch {
                        videoUsesOwnAudio = true
                        status = "Questo video non permette il cambio di tono: suona con l'audio originale."
                    }
                    duration = videoUsesOwnAudio ? (p.currentItem?.asset.duration.seconds ?? 0) : fileAudio.duration
                } else {
                    try fileAudio.load(media.audio)
                    duration = fileAudio.duration
                }
                if let l = sidecar?.lyrics, !l.isEmpty {
                    lyrics = Self.repaired(l); lyricsSource = "testo salvato in FPM Studio Live"
                } else if let f = LyricsSources.find(for: media.audio) ?? (media.audio != item.url ? LyricsSources.find(for: item.url) : nil) {
                    lyrics = f.lyrics; lyricsSource = f.source
                } else if let l = Self.embeddedAssetLyrics(item.url) {
                    lyrics = l; lyricsSource = "testo nei metadati del file (da sincronizzare)"
                } else {
                    lyrics = KaraokeLyrics(title: item.title, artist: item.artist, lines: [])
                    lyricsSource = cdg != nil ? "grafica CDG" : ""
                }
                if lyrics.title == nil { lyrics.title = item.title }
                chords = sidecar?.chords ?? lyrics.chordEvents
                sections = sidecar?.sections ?? []
                if chords.isEmpty || sections.isEmpty { analyzeAudio(media.audio, keepChords: !chords.isEmpty) }
            }
        } catch {
            status = "Impossibile aprire il brano: \(error.localizedDescription)"
            return
        }
        transpose = sidecar?.defaultTranspose ?? 0
        tempo = sidecar?.defaultTempo ?? 1
        if status.isEmpty {
            let n = lyrics.flat.count
            if !lyrics.isEmpty {
                status = "Testo: \(lyricsSource) · \(lyrics.lines.count) righe, \(n) sillabe" + (lyrics.isFullySynced ? "" : " · non sincronizzato: usa \"Testo e accordi → Sincronizza\"")
            } else if cdg != nil {
                status = "Karaoke CD+G: il testo è nella grafica"
            } else {
                status = "Nessun testo trovato in questo brano: aggiungilo con \"Testo e accordi\""
            }
        }
        nextUpTitle = library?.setlist.first(where: { $0 != item })?.title
        if autoplay { play() }
    }

    private func loadLRC(for url: URL) -> KaraokeLyrics? {
        let lrc = url.deletingPathExtension().appendingPathExtension("lrc")
        guard let s = try? String(contentsOf: lrc) else { return nil }
        let l = KaraokeLyrics.fromLRC(s)
        return l.isEmpty ? nil : l
    }

    private func analyzeAudio(_ url: URL, keepChords: Bool) {
        analyzing = true
        let lyr = lyrics
        let current = item?.url
        DispatchQueue.global(qos: .utility).async {
            let r = try? AudioAnalyzer.analyze(url: url)
            DispatchQueue.main.async {
                self.analyzing = false
                guard let r = r, self.item?.url == current else { return }
                self.bpm = r.bpm
                self.keyName = KeyDetector.name(root: r.keyRoot, minor: r.keyMinor, notation: self.settings.notation)
                if !keepChords { self.chords = r.chords }
                if self.sections.isEmpty {
                    let bars = r.bars
                    let input = SongStructureAnalyzer.Input(bars: bars, duration: r.duration, musicStart: r.leadIn, lyrics: lyr.isEmpty ? nil : lyr,
                                                            chords: self.chords, vocalTimes: [], density: bars.map { _ in 1 })
                    self.sections = SongStructureAnalyzer.analyze(input)
                }
            }
        }
    }

    // MARK: Trasporto

    func play() {
        guard let k = kind else { return }
        hub.start()
        advanceWork?.cancel(); countdownToNext = nil
        switch k {
        case .midi: precount ? hub.sequencer.playWithCount() : hub.sequencer.play()
        case .audio: fileAudio.play()
        case .video:
            if videoUsesOwnAudio { videoPlayer?.rate = Float(tempo) } else { fileAudio.play(); videoPlayer?.rate = Float(tempo) }
        }
        isPlaying = true
    }

    func pause() {
        switch kind {
        case .midi: hub.sequencer.pause()
        case .audio: fileAudio.pause()
        case .video: videoPlayer?.pause(); if !videoUsesOwnAudio { fileAudio.pause() }
        case .none: break
        }
        isPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func stop() {
        hub.sequencer.pause()
        hub.sequencer.seek(to: 0)
        fileAudio.stop()
        videoPlayer?.pause()
        videoPlayer?.seek(to: .zero)
        isPlaying = false
        position = 0
        resyncEvents(at: 0)
    }

    func seek(to t: Double) {
        let s = max(0, min(t, duration))
        switch kind {
        case .midi: hub.sequencer.seek(to: s)
        case .audio: fileAudio.seek(to: s)
        case .video:
            if !videoUsesOwnAudio { fileAudio.seek(to: s) }
            videoPlayer?.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        case .none: break
        }
        position = s
        resyncEvents(at: s)
    }

    func skip(_ delta: Double) { seek(to: position + delta) }

    private func applyTransposeTempo() {
        hub.sequencer.setTranspose(transpose)
        hub.sequencer.speed = tempo
        fileAudio.set(transpose: transpose, tempo: tempo)
        if isPlaying, kind == .video { videoPlayer?.rate = Float(tempo) }
    }

    private func tick() {
        guard let k = kind else { return }
        defer { advancedTick(); updateCDG() }
        switch k {
        case .midi: position = hub.sequencer.position
        case .audio: position = fileAudio.position
        case .video:
            if videoUsesOwnAudio {
                position = videoPlayer?.currentTime().seconds ?? 0
                if isPlaying, let p = videoPlayer, p.rate == 0, position >= duration - 0.2 { songEnded() }
            } else {
                position = fileAudio.position
                // Il video segue l'audio.
                if isPlaying, let p = videoPlayer {
                    let vt = p.currentTime().seconds
                    if abs(vt - position) > 0.12 {
                        p.seek(to: CMTime(seconds: position + 0.05, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                }
            }
        }
    }

    /// Testi salvati con versioni precedenti: righe troppo lunghe vengono divise.
    static func repaired(_ l: KaraokeLyrics) -> KaraokeLyrics {
        var r = l
        r.lines = l.lines.flatMap { KaraokeLyrics.splitLongLine($0, forceByPauses: false) }
        return r
    }

    // MARK: CD+G

    private func updateCDG() {
        guard let c = cdg else { return }
        c.advance(to: position)
        guard c.changed || clock.cdgImage == nil else { return }
        let rgba = c.visibleRGBA()
        let w = CDGDecoder.visibleWidth, h = CDGDecoder.visibleHeight
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return }
        clock.cdgImage = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Testo nei metadati di M4A/MP4 (iTunes "©lyr"), anche in formato LRC.
    static func embeddedAssetLyrics(_ url: URL) -> KaraokeLyrics? {
        guard let text = AVURLAsset(url: url).lyrics, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if text.range(of: #"\[\d{1,2}:\d{2}"#, options: .regularExpression) != nil {
            let l = KaraokeLyrics.fromLRC(text)
            if !l.isEmpty { return l }
        }
        return LyricsSources.unsynced(text)
    }

    // MARK: Mixer MIDI

    func setMuted(_ ch: Int, _ m: Bool) {
        guard let i = channels.firstIndex(where: { $0.channel == ch }) else { return }
        channels[i].muted = m
        applyMixer()
    }

    func setSolo(_ ch: Int, _ s: Bool) {
        guard let i = channels.firstIndex(where: { $0.channel == ch }) else { return }
        channels[i].solo = s
        applyMixer()
    }

    func setGain(_ ch: Int, _ g: Double) {
        guard let i = channels.firstIndex(where: { $0.channel == ch }) else { return }
        channels[i].gain = g
        hub.sequencer.setGain(ch, g)
    }

    /// Spegne o accende la melodia (per lasciarla alla voce).
    func toggleMelody() {
        guard let m = melodyChannel, let i = channels.firstIndex(where: { $0.channel == m }) else { return }
        setMuted(m, !channels[i].muted)
    }

    var melodyMuted: Bool { melodyChannel.flatMap { m in channels.first { $0.channel == m }?.muted } ?? false }

    private func applyMixer() {
        let anySolo = channels.contains { $0.solo }
        for c in channels { hub.sequencer.setMuted(c.channel, c.muted || (anySolo && !c.solo)) }
    }

    // MARK: Fine brano e scaletta

    private func songEnded() {
        isPlaying = false
        guard settings.autoAdvance, let lib = library else { return }
        if let cur = item, let i = lib.setlist.firstIndex(of: cur) { lib.setlist.remove(at: i) }
        guard let next = lib.setlist.first else { status = "Scaletta terminata"; return }
        let wait = settings.pauseBetweenSongs
        countdownToNext = wait
        nextUpTitle = next.title
        let start = Date()
        let work = DispatchWorkItem { [weak self] in self?.load(next, autoplay: true) }
        advanceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] t in
            guard let self = self, self.countdownToNext != nil, !work.isCancelled else { t.invalidate(); return }
            self.countdownToNext = max(0, wait - Date().timeIntervalSince(start))
            if self.countdownToNext == 0 { t.invalidate() }
        }
    }

    func playNextNow() {
        guard let lib = library else { return }
        if let cur = item, let i = lib.setlist.firstIndex(of: cur) { lib.setlist.remove(at: i) }
        if let next = lib.setlist.first { load(next, autoplay: true) }
    }

    // MARK: Salvataggio testo/accordi/struttura

    func saveSidecar() {
        guard let it = item else { return }
        var s = SongSidecar.load(for: it.url) ?? SongSidecar()
        s.lyrics = lyrics
        s.chords = chords
        s.sections = sections
        s.lyricsOffset = lyricsOffset
        s.defaultTranspose = transpose
        s.defaultTempo = tempo
        s.melodyChannel = melodyChannel
        s.markers = markers.isEmpty ? nil : markers
        s.events = events.isEmpty ? nil : events
        s.documentPath = documentURL?.path
        do { try s.save(for: it.url); status = "Testo, accordi e struttura salvati" }
        catch { status = "Salvataggio non riuscito: \(error.localizedDescription)" }
    }

    /// Suona le basi MIDI con uno strumento Audio Unit (es. Roland Sound Canvas VA).
    func usePlugin(id: String, name: String) {
        status = "Carico \(name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let s = GMSynth.makePlugin(id: id, name: name)
            DispatchQueue.main.async {
                guard let s = s else { self.status = "Non riesco ad avviare \(name)"; return }
                self.hub.useSynth(s)
                if let m = self.midi { self.hub.sequencer.load(m); self.applyMixerAfterReload() }
                self.status = "Suoni: \(name)"
            }
        }
    }

    private func applyMixerAfterReload() {
        hub.sequencer.setTranspose(transpose)
        hub.sequencer.speed = tempo
        for c in channels { hub.sequencer.setGain(c.channel, c.gain) }
        let anySolo = channels.contains { $0.solo }
        for c in channels { hub.sequencer.setMuted(c.channel, c.muted || (anySolo && !c.solo)) }
    }

    /// Torna ai SoundFont (sintetizzatore di sistema con il .sf2 scelto).
    func useSoundFont() {
        if hub.synth.isPlugin {
            hub.useSynth(GMSynth())
            if let m = midi { hub.sequencer.load(m); applyMixerAfterReload() }
        }
    }

    func reloadSoundFont() {
        settings.synthPluginID = ""
        if settings.soundFontPath == AppSettings.appleSounds {
            hub.useSynth(GMSynth())   // sintetizzatore pulito, senza banchi caricati
            if let m = midi { hub.sequencer.load(m); applyMixerAfterReload() }
            status = "Suoni: \(settings.soundFontName)"
            return
        }
        useSoundFont()
        status = hub.loadSoundBank(path: settings.effectiveSoundFontPath) ? "SoundFont caricato: \(settings.soundFontName)" : "SoundFont non valido"
    }

    /// Accordi trasposti per la visualizzazione.
    func displayChord(_ c: Chord?) -> String {
        guard let c = c else { return "N.C." }
        return c.transposed(transpose).name(settings.notation)
    }

    func currentChordIndex(at t: Double) -> Int? {
        var idx: Int?
        for (i, c) in chords.enumerated() { if c.time <= t + 0.05 { idx = i } else { break } }
        return idx
    }

    var currentSection: SongSection? { sections.last { $0.start <= lyricsTime + 0.01 } }
}

/// Nomi italiani degli strumenti General MIDI.
enum GM {
    static let names: [String] = [
        "Pianoforte a coda", "Pianoforte brillante", "Piano elettrico a coda", "Honky-tonk", "Piano Rhodes", "Piano FM", "Clavicembalo", "Clavinet",
        "Celesta", "Glockenspiel", "Carillon", "Vibrafono", "Marimba", "Xilofono", "Campane tubolari", "Dulcimer",
        "Organo Hammond", "Organo percussivo", "Organo rock", "Organo da chiesa", "Harmonium", "Fisarmonica", "Armonica", "Bandoneón",
        "Chitarra classica", "Chitarra acustica", "Chitarra jazz", "Chitarra elettrica", "Chitarra stoppata", "Chitarra overdrive", "Chitarra distorta", "Armonici chitarra",
        "Contrabbasso", "Basso elettrico (dita)", "Basso elettrico (plettro)", "Basso fretless", "Basso slap 1", "Basso slap 2", "Basso synth 1", "Basso synth 2",
        "Violino", "Viola", "Violoncello", "Contrabbasso archi", "Archi tremolo", "Archi pizzicato", "Arpa", "Timpani",
        "Archi", "Archi lenti", "Archi synth 1", "Archi synth 2", "Coro Aah", "Voce Ooh", "Voce synth", "Orchestra hit",
        "Tromba", "Trombone", "Tuba", "Tromba sordina", "Corno", "Sezione fiati", "Fiati synth 1", "Fiati synth 2",
        "Sax soprano", "Sax contralto", "Sax tenore", "Sax baritono", "Oboe", "Corno inglese", "Fagotto", "Clarinetto",
        "Ottavino", "Flauto", "Flauto dolce", "Flauto di Pan", "Bottiglia", "Shakuhachi", "Fischio", "Ocarina",
        "Lead quadra", "Lead dente di sega", "Lead calliope", "Lead chiff", "Lead charang", "Lead voce", "Lead quinte", "Lead basso+lead",
        "Pad new age", "Pad caldo", "Pad polysynth", "Pad coro", "Pad archetto", "Pad metallico", "Pad halo", "Pad sweep",
        "FX pioggia", "FX colonna sonora", "FX cristallo", "FX atmosfera", "FX luminoso", "FX goblin", "FX eco", "FX sci-fi",
        "Sitar", "Banjo", "Shamisen", "Koto", "Kalimba", "Cornamusa", "Fiddle", "Shanai",
        "Campanella", "Agogo", "Steel drum", "Woodblock", "Taiko", "Tom melodico", "Batteria synth", "Piatto rovesciato",
        "Rumore corde", "Respiro", "Mare", "Uccellini", "Telefono", "Elicottero", "Applausi", "Sparo"
    ]
    static func name(_ p: Int) -> String { names.indices.contains(p) ? names[p] : "Programma \(p)" }
}
