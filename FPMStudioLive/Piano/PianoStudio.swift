import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

/// Piano Studio: dal MIDI ricava accordi e struttura e crea un accompagnamento pianistico
/// professionale (senza melodia) da esportare in MP3/WAV/M4A/MIDI, intero o per parti.
final class PianoStudioModel: ObservableObject {
    enum Scope: String, CaseIterable, Identifiable {
        case whole, selectedJoined, eachSection
        var id: String { rawValue }
        var label: String {
            switch self {
            case .whole: return "Brano intero"
            case .selectedJoined: return "Parti selezionate in un file"
            case .eachSection: return "Ogni parte selezionata in un file separato"
            }
        }
    }

    enum ListenMode: String, CaseIterable, Identifiable {
        case original, piano, pianoMelody
        var id: String { rawValue }
        var label: String {
            switch self {
            case .original: return "Originale (MIDI)"
            case .piano: return "Pianoforte"
            case .pianoMelody: return "Piano + melodia"
            }
        }
    }

    @Published private(set) var sourceURL: URL?
    @Published private(set) var sourceIsAudio = false
    @Published private(set) var midi: MIDIFile?
    @Published private(set) var analysis: ChordEngine.Analysis?
    @Published var sections: [SongSection] = []
    @Published var selected: Set<UUID> = []
    @Published var options = PianoOptions() { didSet { if options != oldValue { generated = nil } } }
    /// Traccia della melodia da togliere (riconosciuta automaticamente, modificabile).
    @Published var melodyChannel: Int? { didSet { generated = nil } }
    @Published private(set) var channelNames: [(ch: Int, name: String)] = []
    @Published var transpose = 0
    @Published var tempo = 1.0
    @Published var mastering: Mastering.Mode = .pro
    @Published var format: ExportFormat = .mp3
    @Published var scope: Scope = .whole
    @Published var reverb: Double = 0
    /// SoundFont del pianoforte, indipendente dal karaoke ("" = lo stesso del karaoke).
    @Published var pianoSoundFont = UserDefaults.standard.string(forKey: "pianoSoundFont") ?? "" {
        didSet { UserDefaults.standard.set(pianoSoundFont, forKey: "pianoSoundFont") }
    }
    @Published var listenMode: ListenMode = .piano
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published var status = ""
    @Published private(set) var chordSummary: [ChordEvent] = []
    @Published private(set) var chordSource = ""
    let preview = PreviewPlayer()
    private(set) var generated: MIDIFile?
    private var regions: [ChordRegion] = []
    private var lyrics: KaraokeLyrics?

    var duration: Double { sourceIsAudio ? (midi?.duration ?? 0) : (midi?.duration ?? 0) }
    var playhead: Double { preview.songPosition }
    var previewing: Bool { preview.isPlaying }

    var pianoSoundFontURL: URL? {
        if pianoSoundFont.isEmpty { return AppSettings.shared.soundFontURL }
        if pianoSoundFont == AppSettings.appleSounds { return nil }
        if pianoSoundFont == "bundled" { return AppSettings.bundledSoundFont }
        return URL(fileURLWithPath: pianoSoundFont)
    }

    /// SoundFont disponibili per il pianoforte.
    var soundFontChoices: [(id: String, name: String)] {
        var out: [(String, String)] = [("", "Come il karaoke (\(AppSettings.shared.soundFontName))"), ("bundled", "GeneralUser GS (incluso)"),
                                       (AppSettings.appleSounds, "Suoni di sistema Apple")]
        let dir = AppPaths.support.appendingPathComponent("SoundFont", isDirectory: true)
        for u in ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            where ["sf2", "dls"].contains(u.pathExtension.lowercased()) {
            out.append((u.path, u.deletingPathExtension().lastPathComponent))
        }
        let custom = AppSettings.shared.soundFontPath
        if !custom.isEmpty, custom != AppSettings.appleSounds, !out.contains(where: { $0.0 == custom }) {
            out.append((custom, URL(fileURLWithPath: custom).deletingPathExtension().lastPathComponent))
        }
        if !pianoSoundFont.isEmpty, !out.contains(where: { $0.0 == pianoSoundFont }) {
            out.append((pianoSoundFont, URL(fileURLWithPath: pianoSoundFont).deletingPathExtension().lastPathComponent))
        }
        return out.map { (id: $0.0, name: $0.1) }
    }

    init() {
        // Il lettore cambia stato: aggiorno la vista (cursore, play/pausa).
        preview.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
    }
    private var bag = Set<AnyCancellable>()

    /// Apre un MIDI/KAR oppure un brano audio (MP3, M4A, WAV, ZIP MP3+G).
    func open(_ url: URL) {
        preview.stop()
        if SongKind.of(url) == .midi { openMIDI(url) } else { openAudio(url) }
    }

    private func openMIDI(_ url: URL) {
        do {
            let m = try MIDIFile(url: url)
            sourceURL = url
            sourceIsAudio = false
            midi = m
            let side = SongSidecar.load(for: url)
            let lyr = side?.lyrics ?? m.karaokeLyrics()
            lyrics = lyr
            let an = ChordEngine.analyze(m, lyrics: lyr, melodyOverride: side?.melodyChannel)
            analysis = an
            melodyChannel = an.melodyChannel
            channelNames = m.usedChannels.filter { $0 != 9 }.map { ch in
                (ch, "Canale \(ch + 1) · " + m.channelDisplayName(ch, extraTitles: [lyr.title, url.deletingPathExtension().lastPathComponent]))
            }
            let embedded = m.embeddedChords()
            if !embedded.isEmpty {
                regions = ChordEngine.regions(fromEmbedded: embedded, midi: m)
                chordSummary = embedded
                chordSource = "accordi scritti dal produttore"
            } else {
                regions = an.regions
                chordSummary = ChordEngine.events(an.regions, midi: m)
                chordSource = "accordi riconosciuti"
            }
            sections = side?.sections ?? SongStructureAnalyzer.fromMarkers(m) ?? SongStructureAnalyzer.analyze(
                SongStructureAnalyzer.input(midi: m, lyrics: lyr, chords: chordSummary, melodyChannel: an.melodyChannel))
            selected = Set(sections.map { $0.id })
            generated = nil
            status = "Tonalità \(KeyDetector.name(root: an.key.root, minor: an.key.minor, notation: AppSettings.shared.notation)) · " +
                "\(chordSummary.count) \(chordSource) · \(sections.count) sezioni" + (SongStructureAnalyzer.fromMarkers(m) != nil ? " (marker del produttore)" : "")
        } catch {
            status = error.localizedDescription
        }
    }

    /// Brano audio: accordi, tempo, battere e struttura ricavati dall'analisi dell'audio.
    private func openAudio(_ url: URL) {
        busy = true; progress = 0; status = "Analizzo il brano audio (accordi, tempo, struttura)…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let audio = try AudioDecode.playableURL(MediaResolver.resolve(url).audio)
                let r = try AudioAnalyzer.analyze(url: audio) { p in DispatchQueue.main.async { self.progress = p } }
                let firstDown = r.bars.first(where: { $0 > 0.05 }) ?? r.leadIn
                let skel = MIDIFile.skeleton(bpm: r.bpm, firstDownbeat: firstDown, duration: r.duration)
                let found = LyricsSources.find(for: url)
                let input = SongStructureAnalyzer.Input(bars: r.bars, duration: r.duration, musicStart: r.leadIn, lyrics: found?.lyrics,
                                                        chords: r.chords, vocalTimes: [], density: r.barEnergy)
                let secs = SongStructureAnalyzer.analyze(input)
                DispatchQueue.main.async {
                    self.busy = false
                    self.sourceURL = url
                    self.sourceIsAudio = true
                    self.midi = skel
                    self.analysis = nil
                    self.melodyChannel = nil
                    self.channelNames = []
                    self.lyrics = found?.lyrics
                    self.regions = ChordEngine.regions(fromEmbedded: r.chords.filter { $0.chord != nil }, midi: skel)
                    self.chordSummary = r.chords
                    self.chordSource = "accordi ricavati dall'audio"
                    self.sections = secs
                    self.selected = Set(secs.map { $0.id })
                    self.generated = nil
                    if self.options.mode != .pianoFromChords { self.options.mode = .pianoFromChords }
                    if self.options.style == .followOriginal { self.options.style = .repeated4 }
                    self.status = "Audio: \(Int(r.bpm.rounded())) BPM · \(KeyDetector.name(root: r.keyRoot, minor: r.keyMinor, notation: AppSettings.shared.notation)) · \(r.chords.count) accordi ricavati dall'audio · \(secs.count) sezioni"
                }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.status = "Non riesco ad analizzare il brano: \(error.localizedDescription)" }
            }
        }
    }

    func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = SongKind.extensions.filter { !["mp4", "mov", "m4v"].contains($0) }.compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    func generate() -> MIDIFile? {
        if let g = generated { return g }
        guard let m = midi else { return nil }
        let data = PianoArranger(midi: m, regions: regions, sections: sections, options: options,
                                 bassChannels: analysis?.bassChannels ?? [], melodyChannel: melodyChannel).arrange()
        generated = try? MIDIFile(data: data)
        return generated
    }

    /// Piano + melodia guida originale (solo per l'ascolto).
    private func pianoWithMelody() -> MIDIFile? {
        guard let g = generate(), let m = midi else { return nil }
        guard let mel = melodyChannel, !sourceIsAudio else { return g }
        var w = MIDIWriter(ppq: m.ppq)
        w.addTrack("Tempo", m.conductorEvents())
        let free = mel == 0 ? 1 : mel
        w.addTrack("Melodia", m.channelEvents([mel], remapTo: [mel: free]))
        w.addTrack("Piano", g.channelEvents([0]))
        return try? MIDIFile(data: w.data())
    }

    func sectionsChanged() { generated = nil; renumber() }

    private func renumber() {
        var c: [SectionKind: Int] = [:]
        for i in sections.indices { c[sections[i].kind, default: 0] += 1; sections[i].number = c[sections[i].kind]! }
    }

    // MARK: Lettore dedicato del Piano Studio (indipendente dal karaoke)

    func togglePreview() {
        if preview.isPlaying { preview.pause(); return }
        if preview.url != nil && preview.title == previewTitle { preview.play(); return }
        startPreview()
    }

    private var previewTitle: String { (sourceURL?.deletingPathExtension().lastPathComponent ?? "") + " · " + listenMode.label }

    func startPreview(at t: Double? = nil) {
        guard let src = sourceURL else { return }
        if listenMode == .original && sourceIsAudio {
            preview.load(src, title: previewTitle, autoplay: true)
            if let t = t { preview.seekSong(t) }
            return
        }
        let file: MIDIFile?
        switch listenMode {
        case .original: file = midi
        case .piano: file = generate()
        case .pianoMelody: file = pianoWithMelody()
        }
        guard let f = file else { return }
        var s = OfflineRenderer.Settings()
        s.soundBank = listenMode == .original ? AppSettings.shared.soundFontURL : pianoSoundFontURL
        s.transpose = transpose
        s.tempo = tempo
        s.reverb = Float(reverb)
        if listenMode != .original { s.pluginID = nil }
        let key = "\(src.path)|\(listenMode.rawValue)|\(options)|\(melodyChannel ?? -1)|\(transpose)|\(tempo)|\(reverb)|\(s.soundBank?.path ?? "apple")|\(sections.map { "\($0.kind.rawValue)\($0.start)" })"
        preview.loadMIDI(f, key: key, title: previewTitle, settings: s, autoplay: true) { [weak self] in
            if let t = t { self?.preview.seekSong(t) }
        }
    }

    /// Clic sulla barra della struttura: il lettore salta lì (e parte, se fermo).
    func seekPreview(_ t: Double) {
        if preview.url == nil || preview.title != previewTitle { startPreview(at: t); return }
        preview.seekSong(t)
        if !preview.isPlaying { preview.play() }
    }

    func export() {
        guard let g = generate(), let src = sourceURL else { return }
        let base = src.deletingPathExtension().lastPathComponent + " - Piano"
        if format == .mid {
            let p = NSSavePanel()
            p.nameFieldStringValue = base + ".mid"
            guard p.runModal() == .OK, let u = p.url else { return }
            let data = PianoArranger(midi: midi!, regions: regions, sections: sections, options: options, bassChannels: analysis?.bassChannels ?? [], melodyChannel: melodyChannel).arrange()
            do { try data.write(to: u); status = "MIDI salvato: \(u.lastPathComponent)" } catch { status = error.localizedDescription }
            return
        }
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Esporta qui"
        p.directoryURL = AppPaths.exports
        guard p.runModal() == .OK, let dir = p.url else { return }
        let chosen = sections.filter { selected.contains($0.id) }
        let scope = self.scope, format = self.format, mastering = self.mastering
        var settings = OfflineRenderer.Settings()
        settings.soundBank = pianoSoundFontURL
        if options.mode == .pianoFromChords { settings.pluginID = nil }
        settings.transpose = transpose
        settings.tempo = tempo
        settings.reverb = Float(reverb)
        busy = true; progress = 0; status = "Genero l'audio…"
        let tempo = self.tempo
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var full = try OfflineRenderer.render(g, settings: settings) { p in DispatchQueue.main.async { self.progress = p * 0.6 } }
                DispatchQueue.main.async { self.status = "Mastering…" }
                Mastering.master(&full.left, &full.right, sr: full.sampleRate, mode: mastering, applyEQ: false)
                var outputs: [(String, RenderedAudio)] = []
                // I tempi delle sezioni sono a velocità originale.
                func part(_ s: SongSection) -> RenderedAudio {
                    full.slice(from: max(0, s.start / tempo - 0.05), to: s.end / tempo + 1.2, fadeIn: 0.02, fadeOut: 1.0)
                }
                switch scope {
                case .whole:
                    outputs = [(base, full)]
                case .selectedJoined:
                    let ordered = chosen.sorted { $0.start < $1.start }
                    // Parti consecutive: un unico taglio; altrimenti unione con breve pausa.
                    var groups: [[SongSection]] = []
                    for s in ordered {
                        if let last = groups.last?.last, abs(last.end - s.start) < 0.05 { groups[groups.count - 1].append(s) } else { groups.append([s]) }
                    }
                    let audios = groups.map { g in full.slice(from: max(0, g.first!.start / tempo - 0.05), to: g.last!.end / tempo + 1.2, fadeOut: 1.0) }
                    outputs = [(base + " - " + ordered.map { $0.title }.joined(separator: "+"), RenderedAudio.concat(audios, gap: 0.6))]
                case .eachSection:
                    outputs = chosen.sorted { $0.start < $1.start }.enumerated().map { i, s in (String(format: "%@ - %02d %@", base, i + 1, s.title), part(s)) }
                }
                for (i, o) in outputs.enumerated() {
                    let url = dir.appendingPathComponent(o.0 + "." + format.rawValue)
                    try AudioExporter.write(o.1, to: url, format: format) { p in
                        DispatchQueue.main.async { self.progress = 0.6 + 0.4 * (Double(i) + p) / Double(outputs.count) }
                    }
                }
                DispatchQueue.main.async {
                    self.busy = false; self.progress = 1
                    self.status = "Esportati \(outputs.count) file in \(dir.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent(outputs[0].0 + "." + format.rawValue)])
                }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.status = error.localizedDescription }
            }
        }
    }
}

struct PianoStudioView: View {
    @ObservedObject var model: PianoStudioModel
    @EnvironmentObject var player: KaraokePlayer
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.contentWidth) private var width

    var body: some View {
        AdaptiveColumns(width: width, threshold: 860, rightWidth: 330) {
            VStack(spacing: 12) {
                Panel(title: "Brano (MIDI o audio)", icon: "pianokeys") {
                    HStack {
                        Text(model.sourceURL?.deletingPathExtension().lastPathComponent ?? "Trascina qui un brano dall'archivio o dal Finder (MIDI, KAR, MP3…)")
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Button("Apri…") { model.chooseFile() }.buttonStyle(NeonButtonStyle())
                    }
                    if model.busy && model.midi == nil { ProgressView(value: model.progress) }
                    if !model.status.isEmpty { Text(model.status).font(.caption).foregroundColor(Theme.soft).fixedSize(horizontal: false, vertical: true) }
                    // Lettore dedicato: ascolti l'originale o il pianoforte mentre lavori, senza toccare il karaoke.
                    HStack {
                        Picker("", selection: $model.listenMode) {
                            ForEach(PianoStudioModel.ListenMode.allCases.filter { !(model.sourceIsAudio && $0 != .piano) }) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 330)
                        Button(model.previewing ? "Pausa" : "Ascolta") { model.togglePreview() }
                            .buttonStyle(NeonButtonStyle()).disabled(model.midi == nil)
                        Button("Da capo") { model.startPreview(at: 0) }.buttonStyle(NeonButtonStyle(prominent: false)).disabled(model.midi == nil)
                    }
                    MiniPlayerView(player: model.preview, acceptsDrop: false)
                }
                Panel(title: "Struttura riconosciuta — scegli le parti", icon: "rectangle.split.3x1") {
                    if model.sections.isEmpty {
                        Text("Nessun brano caricato").font(.caption).foregroundColor(Theme.soft)
                    } else {
                        if let m = model.midi {
                            SectionStrip(sections: model.sections, duration: max(1, m.duration), position: model.playhead) { model.seekPreview($0) }
                                .frame(height: 28)
                            HStack {
                                Text(formatTime(model.playhead)).monospacedDigit()
                                if let s = model.sections.last(where: { $0.start <= model.playhead + 0.01 }), model.previewing {
                                    Text("▶ \(s.title)").bold().foregroundColor(Theme.cyan)
                                }
                                Spacer()
                                Text(formatTime(m.duration)).monospacedDigit()
                            }.font(.caption).foregroundColor(Theme.soft)
                        }
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(Array(model.sections.enumerated()), id: \.element.id) { i, s in
                                    HStack {
                                        Toggle("", isOn: Binding(get: { model.selected.contains(s.id) },
                                                                 set: { on in if on { model.selected.insert(s.id) } else { model.selected.remove(s.id) } })).labelsHidden()
                                        Picker("", selection: Binding(get: { s.kind }, set: { model.sections[i].kind = $0; model.sectionsChanged() })) {
                                            ForEach(SectionKind.allCases) { k in Text("\(k.label) · \(k.italian)").tag(k) }
                                        }.frame(width: 210)
                                        Text("\(formatTime(s.start)) – \(formatTime(s.end))").monospacedDigit().font(.caption)
                                        Spacer()
                                        Text(chordsIn(s)).font(.system(size: 11, design: .rounded)).foregroundColor(Theme.cyan).lineLimit(1)
                                    }
                                }
                            }
                        }.frame(minHeight: 160)
                        HStack {
                            Button("Tutte") { model.selected = Set(model.sections.map { $0.id }) }
                            Button("Nessuna") { model.selected = [] }
                            Button("Solo ritornelli") { model.selected = Set(model.sections.filter { $0.kind == .chorus }.map { $0.id }) }
                        }.font(.caption)
                    }
                }
                Panel(title: "Accordi", icon: "music.quarternote.3") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(Array(model.chordSummary.prefix(200).enumerated()), id: \.offset) { _, c in
                                Text(c.chord.map { $0.transposed(model.transpose).name(settings.notation) } ?? "N.C.")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
                            }
                        }
                    }
                }
            }
        } right: {
            VStack(spacing: 12) {
                Panel(title: "Tipo di base", icon: "square.stack.3d.up") {
                    Picker("", selection: $model.options.mode) { ForEach(AccompanimentMode.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.radioGroup).labelsHidden()
                    Picker("Melodia da togliere", selection: Binding(get: { model.melodyChannel ?? -1 }, set: { model.melodyChannel = $0 < 0 ? nil : $0 })) {
                        Text("Nessuna").tag(-1)
                        ForEach(model.channelNames, id: \.ch) { c in Text(c.name).tag(c.ch) }
                    }
                    Text(model.options.mode == .pianoFromChords
                         ? "Il pianoforte suona gli accordi di tutto il brano, dalla prima all'ultima battuta, senza melodia."
                         : "Tutti gli strumenti del MIDI dall'inizio alla fine, tolta solo la traccia della melodia.")
                        .font(.caption).foregroundColor(Theme.soft).fixedSize(horizontal: false, vertical: true)
                }
                Panel(title: "Pianoforte", icon: "slider.horizontal.3") {
                    Picker("Stile", selection: $model.options.style) { ForEach(PianoStyle.allCases) { Text($0.label).tag($0) } }
                    Picker("Suono", selection: $model.options.program) {
                        Text("Gran coda").tag(0); Text("Pianoforte brillante").tag(1); Text("Piano elettrico a coda").tag(2); Text("Rhodes").tag(4)
                    }
                    Picker("Accordi", selection: $model.options.simplifyToTriads) {
                        Text("Originali (con 7ª, 6ª…)").tag(false)
                        Text("Solo maggiori e minori").tag(true)
                    }.pickerStyle(.segmented)
                    if model.options.mode == .pianoFromChords {
                        Toggle("Aggiungi basso originale", isOn: $model.options.keepOriginalBass)
                        Toggle("Aggiungi batteria originale", isOn: $model.options.keepOriginalDrums)
                    }
                    Toggle("Umanizza (tempi e dinamiche)", isOn: $model.options.humanize)
                    Toggle("Rallentando e accordo finale", isOn: $model.options.finalRitardando)
                    HStack { Text("Dinamica"); Slider(value: $model.options.dynamics, in: 0.6...1.3) }
                }
                Panel(title: "Tono e tempo", icon: "tuningfork") {
                    Stepper("Tonalità: \(model.transpose > 0 ? "+" : "")\(model.transpose) semitoni", value: $model.transpose, in: -12...12)
                    HStack { Text("Velocità \(Int(model.tempo * 100))%"); Slider(value: $model.tempo, in: 0.6...1.4, step: 0.01) }
                    HStack { Text("Ambiente"); Slider(value: $model.reverb, in: 0...50) }
                }
                Panel(title: "Esporta", icon: "square.and.arrow.up") {
                    Picker("Formato", selection: $model.format) { ForEach(ExportFormat.allCases) { Text($0.label).tag($0) } }
                    Picker("Parti", selection: $model.scope) { ForEach(PianoStudioModel.Scope.allCases) { Text($0.label).tag($0) } }
                    Picker("Mastering", selection: $model.mastering) { ForEach(Mastering.Mode.allCases) { Text($0.label).tag($0) } }
                    Picker("SoundFont del piano", selection: $model.pianoSoundFont) {
                        ForEach(model.soundFontChoices, id: \.id) { c in Text(c.name).tag(c.id) }
                    }
                    HStack {
                        Button("Crea \(model.format == .mid ? "MIDI" : "audio")") { model.export() }
                            .buttonStyle(NeonButtonStyle()).disabled(model.midi == nil || model.busy || (model.scope != .whole && model.selected.isEmpty))
                    }
                    if model.busy { ProgressView(value: model.progress).accentColor(Theme.violet) }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            DropHelper.urls(from: providers) { urls in
                if let u = urls.first(where: { SongKind.of($0) != nil && SongKind.of($0) != .video }) { model.open(u) }
            }
            return true
        }
    }

    private func chordsIn(_ s: SongSection) -> String {
        var names: [String] = []
        for c in model.chordSummary where c.time >= s.start - 0.05 && c.time < s.end {
            let n = c.chord.map { $0.transposed(model.transpose).name(settings.notation) } ?? "N.C."
            if names.last != n { names.append(n) }
            if names.count >= 8 { break }
        }
        return names.joined(separator: " · ")
    }
}
