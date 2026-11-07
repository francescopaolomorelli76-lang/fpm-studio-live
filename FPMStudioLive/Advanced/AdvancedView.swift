import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Stato reale di ogni requisito del capitolato (nessun pulsante finto: ciò che manca è dichiarato).
struct FeatureStatus: Identifiable {
    enum State: String { case done = "Implementata", limited = "Limitata", missing = "Non ancora disponibile" }
    var id: String
    var area: String
    var title: String
    var state: State
    var note: String

    static let all: [FeatureStatus] = [
        .init(id: "REQ-A01", area: "Player", title: "MIDI/KAR, MP3/WAV/M4A, MP4/MOV, LRC", state: .limited, note: "Mancano CDG, AVI/FLV, WMA e link YouTube"),
        .init(id: "REQ-A02", area: "Player", title: "File picker, drag & drop, cartelle, archivio", state: .done, note: ""),
        .init(id: "REQ-A03", area: "Player", title: "Transport, tempo trascorso/rimanente, BPM, tonalità, pre-count, metronomo", state: .limited, note: "Metronomo e pre-count solo sulle basi MIDI"),
        .init(id: "REQ-A04", area: "Player", title: "Tono, tempo indipendente, volumi, mute/solo, EQ, compressore", state: .limited, note: "Compressore solo nell'export"),
        .init(id: "REQ-A05", area: "Player", title: "Prenotazione brano successivo", state: .done, note: "Scaletta con avanti automatico"),
        .init(id: "REQ-A06", area: "Player", title: "Comportamenti fine brano (stop, auto, casuale)", state: .limited, note: "Stop o avanti automatico; casuale non ancora"),
        .init(id: "REQ-A07", area: "Player", title: "Preferiti, cronologia, ripristino sessione, schermo palco", state: .limited, note: "Ripristino scaletta e impostazioni; preferiti/cronologia in roadmap"),
        .init(id: "REQ-B01", area: "Archivio", title: "Database SQLite completo", state: .limited, note: "Archivio JSON + file .fpm.json per brano"),
        .init(id: "REQ-B02", area: "Archivio", title: "39 SongList + F10 + F11/F12", state: .missing, note: "Oggi: una scaletta serata + playlist automix"),
        .init(id: "REQ-B07", area: "Archivio", title: "Backup incrementale e sync", state: .missing, note: ""),
        .init(id: "REQ-C01", area: "Karaoke", title: "Karaoke a sillaba, LRC, offset", state: .done, note: "SRT non ancora"),
        .init(id: "REQ-C02", area: "Karaoke", title: "Editor testo con sincronizzazione", state: .limited, note: "Sincronizzazione da tastiera; senza waveform"),
        .init(id: "REQ-C03", area: "Karaoke", title: "Editor accordi, notazione latina/internazionale, riconoscimento MIDI", state: .done, note: ""),
        .init(id: "REQ-C04", area: "Karaoke", title: "Chord Bar + tastiera + diagrammi chitarra", state: .done, note: ""),
        .init(id: "REQ-C05", area: "Karaoke", title: "Struttura Intro/Verse/Chorus/Bridge/Outro, marker, loop", state: .done, note: ""),
        .init(id: "REQ-C06", area: "Karaoke", title: "Doppio monitor con overlay testi/accordi su video", state: .done, note: ""),
        .init(id: "REQ-C07", area: "Karaoke", title: "Karaoke Web Monitor con QR, font/colori per spettatore", state: .limited, note: "Solo rete locale (LAN), non via Internet"),
        .init(id: "REQ-C08", area: "Karaoke", title: "Messaggi a schermo, leggio PDF con pedale", state: .done, note: "Slideshow sfondi in roadmap"),
        .init(id: "REQ-C09", area: "Karaoke", title: "Songbook stampabile", state: .missing, note: ""),
        .init(id: "REQ-D01", area: "Multitraccia", title: "Fino a 16 stem sincronizzate, gain/pan/mute/solo", state: .done, note: "Senza waveform per traccia"),
        .init(id: "REQ-D02", area: "Multitraccia", title: "\"Non trasporre\" per stem (batteria/click esclusi di default)", state: .done, note: ""),
        .init(id: "REQ-D04", area: "Multitraccia", title: "4 uscite indipendenti (FOH, click, monitor, cue)", state: .missing, note: "Richiede routing multicanale CoreAudio"),
        .init(id: "REQ-D06", area: "Multitraccia", title: "Progetto aperto (.stageproj.json)", state: .done, note: "WMT/MP3+/WEVN non supportati (formati proprietari)"),
        .init(id: "REQ-E01", area: "MIDI", title: "Parser SMF/KAR, tempo map, testi", state: .done, note: ""),
        .init(id: "REQ-E02", area: "MIDI", title: "Synth GM con SoundFont SF2/DLS", state: .done, note: "SFZ non supportato"),
        .init(id: "REQ-E03", area: "MIDI", title: "Mixer canali: volume, mute/solo", state: .limited, note: "Pan/effetti per canale in roadmap"),
        .init(id: "REQ-E04", area: "MIDI", title: "Device manager MIDI, MIDI learn, clock", state: .missing, note: ""),
        .init(id: "REQ-E05", area: "MIDI", title: "Piano roll / drum editor", state: .missing, note: ""),
        .init(id: "REQ-E08", area: "MIDI", title: "Melodia on/off, solo melodia, basso+batteria, solo batteria, reset", state: .done, note: "Tasti M U B D A N"),
        .init(id: "REQ-E09", area: "MIDI", title: "MIDI → WAV/MP3 offline", state: .done, note: "Piano Studio e AI Studio"),
        .init(id: "REQ-F01", area: "Eventi", title: "Timeline eventi (KEY, TEMPO, VOLUME, FADE, MSG, PDF PAGNUM, SAMPLE, START MIX, metronomo)", state: .done, note: "Tempo in secondi; SysEx non inviato"),
        .init(id: "REQ-F02", area: "Eventi", title: "Replay deterministico dopo seek/loop", state: .done, note: "Verificato nei test"),
        .init(id: "REQ-F03", area: "Eventi", title: "10 marker, loop con ripetizioni, quick save", state: .done, note: ""),
        .init(id: "REQ-F04", area: "Eventi", title: "Pedale/tastiera mappabili", state: .limited, note: "Pedali Bluetooth \"tastiera\" sì; pedali MIDI no"),
        .init(id: "REQ-G01", area: "Mix", title: "Crossfade automatico/manuale, curve", state: .done, note: "Nella sezione DJ"),
        .init(id: "REQ-G03", area: "Mix", title: "Medley Creator fino a 6 brani con export", state: .done, note: ""),
        .init(id: "REQ-G04", area: "Mix", title: "Musica di sottofondo automatica", state: .done, note: ""),
        .init(id: "REQ-G05", area: "Mix", title: "Sample player 100 slot", state: .done, note: "Hotkey per slot in roadmap"),
        .init(id: "REQ-H01", area: "AI", title: "Separazione stem con AI", state: .missing, note: "Serve un modello (es. Demucs) o un servizio a pagamento"),
        .init(id: "REQ-H02", area: "AI", title: "Stima tonalità, BPM, accordi", state: .done, note: "Algoritmi locali, risultati modificabili"),
        .init(id: "REQ-I03", area: "Registrazione", title: "Registrazione voce sulla base", state: .limited, note: "Voce in WAV separato; mixdown con la base in roadmap"),
        .init(id: "REQ-I04", area: "Registrazione", title: "Screen/video capture", state: .missing, note: ""),
        .init(id: "REQ-L01", area: "Rete", title: "Telecomando LAN con PIN", state: .limited, note: "HTTP su rete locale, senza TLS"),
        .init(id: "REQ-L03", area: "Rete", title: "Cloud backup", state: .missing, note: ""),
        .init(id: "REQ-N01", area: "Scorciatoie", title: "Profilo rimappabile con conflitti evidenziati", state: .done, note: ""),
        .init(id: "REQ-O05", area: "Live", title: "Show lock", state: .done, note: "")
    ]
}

struct AdvancedView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case markers, chords, leggio, sampler, multitrack, medley, background, web, record, keys, status
        var id: String { rawValue }
        var label: String {
            switch self {
            case .markers: return "Marker ed eventi"
            case .chords: return "Chord Bar"
            case .leggio: return "Leggio PDF"
            case .sampler: return "Campionatore"
            case .multitrack: return "Multitraccia"
            case .medley: return "Medley"
            case .background: return "Sottofondo"
            case .web: return "Web Monitor"
            case .record: return "Registra"
            case .keys: return "Scorciatoie"
            case .status: return "Stato funzioni"
            }
        }
    }

    @ObservedObject var player: KaraokePlayer
    @ObservedObject var sampler: SamplerEngine
    @ObservedObject var multitrack: MultitrackPlayer
    @ObservedObject var medley: MedleyCreator
    @ObservedObject var background: BackgroundMusic
    @ObservedObject var web: WebMonitor
    @ObservedObject var recorder: VoiceRecorder
    @ObservedObject var shortcuts: ShortcutManager
    @ObservedObject var settings = AppSettings.shared
    @State private var tab: Tab = .markers

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(Tab.allCases) { t in Chip(text: t.label, selected: tab == t) { tab = t } } }
                }
                Toggle(isOn: $settings.showLock) { Label("Show lock", systemImage: settings.showLock ? "lock.fill" : "lock.open") }
                    .toggleStyle(.switch).help("Blocca le modifiche durante lo spettacolo")
            }
            Panel(title: tab.label) {
                Group {
                    switch tab {
                    case .markers: MarkersEventsPanel(player: player, locked: settings.showLock)
                    case .chords: ChordBarView(player: player)
                    case .leggio: LeggioView(player: player).frame(minHeight: 420)
                    case .sampler: SamplerPanel(sampler: sampler, locked: settings.showLock)
                    case .multitrack: MultitrackPanel(mt: multitrack)
                    case .medley: MedleyPanel(medley: medley)
                    case .background: BackgroundPanel(bg: background)
                    case .web: WebPanel(web: web)
                    case .record: RecordPanel(recorder: recorder, player: player)
                    case .keys: ShortcutsEditor(shortcuts: shortcuts)
                    case .status: StatusPanel()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: Marker ed eventi

struct MarkersEventsPanel: View {
    @ObservedObject var player: KaraokePlayer
    var locked: Bool
    @State private var newKind: LiveEvent.Kind = .keyChange

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("MARKER (\(player.markers.count)/\(SongMarker.maxCount))").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.soft)
                    Spacer()
                    Button("+ Marker qui (K)") { player.addMarker() }.buttonStyle(NeonButtonStyle()).disabled(player.item == nil || locked)
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(player.markers.enumerated()), id: \.element.id) { i, m in
                            HStack(spacing: 6) {
                                Button(action: { player.jump(to: m) }) { Image(systemName: "play.fill") }.buttonStyle(NeonButtonStyle(prominent: false))
                                TextField("Nome", text: Binding(get: { m.name }, set: { player.markers[i].name = $0 })).frame(width: 110).disabled(locked)
                                Text(formatTime(m.time)).monospacedDigit().font(.caption)
                                if let e = m.loopEnd { Text("→ \(formatTime(e))").monospacedDigit().font(.caption) }
                                Button("Fine loop qui") { player.markers[i].loopEnd = max(m.time + 0.5, player.position) }.font(.caption).disabled(locked)
                                Stepper("×\(m.repeats == 0 ? "∞" : String(m.repeats))", value: Binding(get: { m.repeats }, set: { player.markers[i].repeats = $0 }), in: 0...16)
                                    .font(.caption).disabled(locked)
                                Button(player.activeLoop == m.id ? "Loop ON" : "Loop") { player.toggleLoop(m) }
                                    .buttonStyle(NeonButtonStyle(prominent: player.activeLoop == m.id))
                                Button(action: { player.markers.remove(at: i) }) { Image(systemName: "trash") }.buttonStyle(.plain).disabled(locked)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Toggle("Metronomo (C)", isOn: $player.metronome).toggleStyle(.switch)
                    Toggle("Pre-count di una battuta", isOn: $player.precount).toggleStyle(.switch)
                }.disabled(player.kind != .midi)
                if player.kind != .midi { Text("Metronomo e pre-count: disponibili sulle basi MIDI.").font(.caption).foregroundColor(Theme.soft) }
                HStack {
                    Text("Modalità canali:").font(.caption)
                    Button("Tutti (A)") { player.applyChannelMode(.all) }
                    Button("Solo melodia (U)") { player.applyChannelMode(.melodyOnly) }
                    Button("Basso+batteria (B)") { player.applyChannelMode(.bassAndDrums) }
                    Button("Solo batteria (D)") { player.applyChannelMode(.drumsOnly) }
                    Button("Reset (N)") { player.resetChannels() }
                }.font(.caption).disabled(player.kind != .midi)
            }.frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("EVENTI SULLA TIMELINE").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.soft)
                    Spacer()
                    Picker("", selection: $newKind) { ForEach(LiveEvent.Kind.allCases) { Text($0.label).tag($0) } }.frame(width: 230)
                    Button("+ alla posizione attuale") { player.addEvent(newKind) }.buttonStyle(NeonButtonStyle()).disabled(player.item == nil || locked)
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(Array(player.events.enumerated()), id: \.element.id) { i, e in
                            HStack(spacing: 6) {
                                Toggle("", isOn: Binding(get: { e.enabled }, set: { player.events[i].enabled = $0 })).labelsHidden()
                                Text(formatTime(e.time)).monospacedDigit().font(.caption).frame(width: 44)
                                Stepper("", value: Binding(get: { e.time }, set: { player.events[i].time = max(0, $0) }), step: 0.1).labelsHidden()
                                Text(e.kind.label).font(.system(size: 11, weight: .semibold)).frame(width: 170, alignment: .leading)
                                if e.kind.usesValue {
                                    TextField("valore", value: Binding(get: { e.value }, set: { player.events[i].value = $0 }), formatter: NumberFormatter()).frame(width: 60)
                                }
                                if e.kind.usesText {
                                    TextField(e.kind == .jumpToMarker ? "nome marker" : "testo", text: Binding(get: { e.text }, set: { player.events[i].text = $0 }))
                                }
                                Spacer()
                                Button(action: { player.events.remove(at: i) }) { Image(systemName: "trash") }.buttonStyle(.plain)
                            }.disabled(locked)
                        }
                    }
                }
                Text("Valori: KEY CHANGE in semitoni, TEMPO in %, VOLUME in %, FADE in secondi, PDF PAGNUM = pagina, SAMPLE = numero slot. Dopo un salto o un loop lo stato (tono, tempo, volume, messaggio, pagina) viene ricalcolato, senza eseguire due volte gli eventi.")
                    .font(.caption).foregroundColor(Theme.soft)
                HStack {
                    Spacer()
                    Button("Salva marker ed eventi") { player.saveSidecar() }.buttonStyle(NeonButtonStyle()).disabled(player.item == nil || locked)
                }
            }.frame(maxWidth: .infinity)
        }
    }
}

// MARK: Campionatore

struct SamplerPanel: View {
    @ObservedObject var sampler: SamplerEngine
    var locked: Bool
    @State private var editing: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ForEach(0..<5, id: \.self) { p in Chip(text: "Banco \(p + 1)", selected: sampler.page == p) { sampler.page = p } }
                Spacer()
                Text("Volume").font(.caption); Slider(value: $sampler.masterVolume, in: 0...1.5).frame(width: 120)
                Button("Stop tutti") { sampler.stopAll() }.buttonStyle(NeonButtonStyle(prominent: false))
            }
            let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
            LazyVGrid(columns: cols, spacing: 8) {
                ForEach(sampler.slots[(sampler.page * 20)..<(sampler.page * 20 + 20)]) { s in
                    Button(action: { if s.path == nil { if !locked { choose(s.id) } } else { sampler.trigger(s.id) } }) {
                        VStack(spacing: 2) {
                            Text("\(s.id)").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.soft)
                            Text(s.path == nil ? "vuoto" : s.name).font(.system(size: 12, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                            if s.loop { Image(systemName: "repeat").font(.system(size: 9)) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 62)
                        .background(RoundedRectangle(cornerRadius: 10).fill(sampler.playing.contains(s.id) ? Theme.magenta.opacity(0.7) : (s.path == nil ? Theme.bg2 : Theme.violet.opacity(0.3))))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Scegli file…") { choose(s.id) }
                        Button(s.loop ? "Togli loop" : "Loop") { if let i = sampler.slots.firstIndex(where: { $0.id == s.id }) { sampler.slots[i].loop.toggle() } }
                        Menu("Gruppo di stop") {
                            ForEach(0..<5, id: \.self) { g in
                                Button(g == 0 ? "Nessuno" : "Gruppo \(g)") { if let i = sampler.slots.firstIndex(where: { $0.id == s.id }) { sampler.slots[i].stopGroup = g } }
                            }
                        }
                        Menu("Volume") {
                            ForEach([0.25, 0.5, 0.75, 1.0, 1.25], id: \.self) { v in
                                Button("\(Int(v * 100))%") { if let i = sampler.slots.firstIndex(where: { $0.id == s.id }) { sampler.slots[i].volume = v } }
                            }
                        }
                        Button("Svuota") { sampler.clear(s.id) }
                    }
                    .disabled(locked && s.path == nil)
                }
            }
            Text("Clic: suona/ferma · tasto destro: file, loop, gruppo di stop, volume. Gli eventi CUSTOM SAMPLE della timeline suonano lo slot indicato.")
                .font(.caption).foregroundColor(Theme.soft)
        }
    }

    private func choose(_ id: Int) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        if p.runModal() == .OK, let u = p.url { sampler.assign(u, to: id) }
    }
}

// MARK: Multitraccia

struct MultitrackPanel: View {
    @ObservedObject var mt: MultitrackPlayer
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Apri cartella stem…") {
                    let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false
                    if p.runModal() == .OK, let u = p.url { mt.loadFolder(u) }
                }.buttonStyle(NeonButtonStyle())
                Text(mt.title).font(.system(size: 14, weight: .bold))
                Spacer()
                Text(mt.status).font(.caption).foregroundColor(Theme.soft)
            }
            HStack(spacing: 10) {
                Button(action: { mt.isPlaying ? mt.pause() : mt.play() }) { Image(systemName: mt.isPlaying ? "pause.fill" : "play.fill").frame(width: 30) }.buttonStyle(NeonButtonStyle())
                Button(action: { mt.stop() }) { Image(systemName: "stop.fill") }.buttonStyle(NeonButtonStyle(prominent: false))
                Text(formatTime(mt.position)).monospacedDigit()
                Slider(value: Binding(get: { mt.position }, set: { mt.seek($0) }), in: 0...max(1, mt.duration))
                Text(formatTime(mt.duration)).monospacedDigit()
            }
            HStack {
                Stepper("Tono \(mt.transpose > 0 ? "+" : "")\(mt.transpose)", value: $mt.transpose, in: -12...12)
                Text("Tempo \(Int(mt.tempo * 100))%"); Slider(value: $mt.tempo, in: 0.7...1.3).frame(width: 160)
                Spacer()
                Button("Salva progetto") { mt.save() }.buttonStyle(NeonButtonStyle(prominent: false)).disabled(mt.stems.isEmpty)
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(mt.stems.enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 8) {
                            Text(s.name).font(.system(size: 12, weight: .semibold)).frame(width: 150, alignment: .leading).lineLimit(1)
                            Slider(value: Binding(get: { s.gain }, set: { mt.stems[i].gain = $0 }), in: 0...1.5).frame(width: 120)
                            Text("Pan").font(.caption); Slider(value: Binding(get: { s.pan }, set: { mt.stems[i].pan = $0 }), in: -1...1).frame(width: 80)
                            Button("M") { mt.stems[i].mute.toggle() }.buttonStyle(MiniToggleStyle(on: s.mute, color: .red))
                            Button("S") { mt.stems[i].solo.toggle() }.buttonStyle(MiniToggleStyle(on: s.solo, color: Theme.warn))
                            Toggle("Non trasporre", isOn: Binding(get: { s.noTranspose }, set: { mt.stems[i].noTranspose = $0 })).font(.caption)
                            Spacer()
                        }
                    }
                }
            }
            Text("Fino a 16 file audio nella stessa cartella partono insieme, sincronizzati. Batteria, percussioni e click sono esclusi dalla trasposizione in automatico. Il progetto si salva come progetto.stageproj.json nella cartella. Uscite separate (click/monitor) non ancora disponibili.")
                .font(.caption).foregroundColor(Theme.soft)
        }
    }
}

// MARK: Medley

struct MedleyPanel: View {
    @ObservedObject var medley: MedleyCreator
    @State private var format: ExportFormat = .wav

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("+ Aggiungi brano (\(medley.items.count)/\(MedleyCreator.maxItems))") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = true
                    if p.runModal() == .OK { p.urls.forEach { medley.add($0) } }
                }.buttonStyle(NeonButtonStyle()).disabled(medley.items.count >= MedleyCreator.maxItems)
                Spacer()
                Text("Durata totale \(formatTime(medley.totalDuration))").font(.system(size: 13, weight: .bold))
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(medley.items.enumerated()), id: \.element.id) { i, it in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(i + 1). \(it.url.deletingPathExtension().lastPathComponent)").font(.system(size: 12, weight: .bold))
                                Spacer()
                                Button(action: { if i > 0 { medley.items.swapAt(i, i - 1) } }) { Image(systemName: "arrow.up") }.buttonStyle(.plain)
                                Button(action: { if i < medley.items.count - 1 { medley.items.swapAt(i, i + 1) } }) { Image(systemName: "arrow.down") }.buttonStyle(.plain)
                                Button(action: { medley.items.remove(at: i) }) { Image(systemName: "trash") }.buttonStyle(.plain)
                            }
                            HStack {
                                field("Inizio", Binding(get: { it.start }, set: { medley.items[i].start = max(0, min($0, it.end - 1)) }), 0...it.duration)
                                field("Fine", Binding(get: { it.end }, set: { medley.items[i].end = max(it.start + 1, min($0, it.duration)) }), 0...it.duration)
                                field("Fade in", Binding(get: { it.fadeIn }, set: { medley.items[i].fadeIn = $0 }), 0...10)
                                field("Fade out", Binding(get: { it.fadeOut }, set: { medley.items[i].fadeOut = $0 }), 0...15)
                                field("Incrocio", Binding(get: { it.crossfade }, set: { medley.items[i].crossfade = $0 }), 0...12)
                                field("Gain dB", Binding(get: { it.gainDb }, set: { medley.items[i].gainDb = $0 }), -12...6)
                            }
                        }
                        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
                    }
                }
            }
            HStack {
                Toggle("Normalizza (-16 LUFS)", isOn: $medley.normalize).toggleStyle(.switch)
                Picker("", selection: $format) { Text("WAV").tag(ExportFormat.wav); Text("MP3").tag(ExportFormat.mp3); Text("M4A").tag(ExportFormat.m4a) }.frame(width: 100)
                Spacer()
                if medley.busy { ProgressView(value: medley.progress).frame(width: 140) }
                Text(medley.status).font(.caption).foregroundColor(Theme.cyan)
                Button("Esporta medley") {
                    let p = NSSavePanel(); p.nameFieldStringValue = "Medley." + format.rawValue
                    if p.runModal() == .OK, let u = p.url { medley.export(to: u, format: format) }
                }.buttonStyle(NeonButtonStyle()).disabled(medley.items.isEmpty || medley.busy)
            }
        }
    }

    private func field(_ label: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.hasPrefix("Gain") ? String(format: "%@ %+.1f", label, v.wrappedValue) : String(format: "%@ %.1f s", label, v.wrappedValue))
                .font(.system(size: 10)).foregroundColor(Theme.soft)
            Slider(value: v, in: r).controlSize(.mini)
        }
    }
}

// MARK: Sottofondo

struct BackgroundPanel: View {
    @ObservedObject var bg: BackgroundMusic
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Musica di sottofondo automatica quando il palco è fermo", isOn: $bg.enabled).toggleStyle(.switch)
            HStack {
                Text("Volume"); Slider(value: $bg.volume, in: 0...1).frame(width: 160)
                Text("Parte dopo \(Int(bg.delayAfterSong)) s"); Slider(value: $bg.delayAfterSong, in: 1...30, step: 1).frame(width: 140)
                Toggle("Casuale", isOn: $bg.shuffle)
            }
            HStack {
                Text(bg.isPlaying ? "♪ \(bg.current)" : "In attesa").foregroundColor(Theme.cyan)
                Spacer()
                Button("Aggiungi brani…") {
                    let p = NSOpenPanel(); p.allowedContentTypes = [.audio]; p.allowsMultipleSelection = true
                    if p.runModal() == .OK { bg.playlist += p.urls }
                }.buttonStyle(NeonButtonStyle(prominent: false))
                Button("Successivo") { bg.playNext() }.buttonStyle(NeonButtonStyle(prominent: false)).disabled(bg.playlist.isEmpty)
                Button("Svuota") { bg.playlist.removeAll() }.buttonStyle(NeonButtonStyle(prominent: false))
            }
            List { ForEach(bg.playlist, id: \.self) { Text($0.deletingPathExtension().lastPathComponent) }.onDelete { bg.playlist.remove(atOffsets: $0) } }
                .frame(minHeight: 160)
            Text("Sfuma da sola quando parte un brano del karaoke e riparte quando si ferma.").font(.caption).foregroundColor(Theme.soft)
        }
    }
}

// MARK: Web Monitor

struct WebPanel: View {
    @ObservedObject var web: WebMonitor
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Button(web.running ? "Ferma Web Monitor" : "Avvia Web Monitor") { web.toggle() }.buttonStyle(NeonButtonStyle(prominent: !web.running))
                if web.running {
                    Text("Testo per il pubblico (telefoni sulla stessa rete Wi-Fi):").font(.caption).foregroundColor(Theme.soft)
                    Text(web.url).font(.system(size: 14, weight: .bold, design: .monospaced)).textSelection(.enabled)
                    Text("Spettatori collegati: \(web.clients)").font(.caption)
                    Divider()
                    Toggle("Telecomando dal telefono (PIN \(web.pin))", isOn: $web.allowRemote).toggleStyle(.switch)
                    if web.allowRemote { Text(web.remoteURL).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                }
                if let e = web.error { Text(e).foregroundColor(Theme.warn).font(.caption) }
                Text("Funziona solo in rete locale. Ogni spettatore può cambiare carattere, dimensione e colori dal pulsante Aa. Il link cambia a ogni avvio e smette di funzionare quando fermi il server.")
                    .font(.caption).foregroundColor(Theme.soft).fixedSize(horizontal: false, vertical: true)
            }
            if let img = web.qr {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 220, height: 220).background(Color.white).cornerRadius(8)
            }
        }
    }
}

// MARK: Registrazione

struct RecordPanel: View {
    @ObservedObject var recorder: VoiceRecorder
    @ObservedObject var player: KaraokePlayer
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(action: { recorder.toggle(songTitle: player.item?.title) }) {
                    Label(recorder.recording ? "Ferma registrazione" : "Registra la voce", systemImage: recorder.recording ? "stop.circle.fill" : "record.circle")
                }.buttonStyle(NeonButtonStyle(prominent: !recorder.recording))
                if recorder.recording { Circle().fill(Color.red).frame(width: 12, height: 12) }
                Spacer()
                Button("Apri cartella registrazioni") { NSWorkspace.shared.open(recorder.folder) }.buttonStyle(NeonButtonStyle(prominent: false))
            }
            Text(recorder.status).font(.caption).foregroundColor(Theme.cyan)
            Text("Registra il microfono in un file WAV 24 bit separato mentre suona la base (usa le cuffie per non registrare anche la musica). Il mix voce + base in un unico file arriverà in una versione successiva.")
                .font(.caption).foregroundColor(Theme.soft)
        }
    }
}

// MARK: Stato funzioni

struct StatusPanel: View {
    var body: some View {
        let all = FeatureStatus.all
        let done = all.filter { $0.state == .done }.count, lim = all.filter { $0.state == .limited }.count
        VStack(alignment: .leading, spacing: 8) {
            Text("\(done) implementate · \(lim) limitate · \(all.count - done - lim) non ancora disponibili (su \(all.count) requisiti principali del capitolato Win Live 16)")
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(all) { f in
                        HStack(alignment: .top) {
                            Text(f.id).font(.system(size: 11, design: .monospaced)).frame(width: 70, alignment: .leading)
                            Text(f.area).font(.system(size: 11)).foregroundColor(Theme.soft).frame(width: 90, alignment: .leading)
                            Text(f.title).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                            Text(f.state.rawValue).font(.system(size: 11, weight: .bold))
                                .foregroundColor(f.state == .done ? Theme.cyan : (f.state == .limited ? Theme.warn : Theme.soft)).frame(width: 150, alignment: .leading)
                            Text(f.note).font(.system(size: 11)).foregroundColor(Theme.soft).frame(width: 260, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}
