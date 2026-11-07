import SwiftUI
import AppKit
import UniformTypeIdentifiers

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

    @Published private(set) var sourceURL: URL?
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
    @Published var reverb: Double = 18
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published var status = ""
    @Published private(set) var chordSummary: [ChordEvent] = []
    @Published private(set) var previewing = false
    private(set) var generated: MIDIFile?
    private var lyrics: KaraokeLyrics?
    private var savedOnEnd: (() -> Void)?

    func open(_ url: URL) {
        do {
            let m = try MIDIFile(url: url)
            sourceURL = url
            midi = m
            let side = SongSidecar.load(for: url)
            let lyr = side?.lyrics ?? m.karaokeLyrics()
            lyrics = lyr
            let an = ChordEngine.analyze(m, lyrics: lyr, melodyOverride: side?.melodyChannel)
            analysis = an
            melodyChannel = an.melodyChannel
            channelNames = m.usedChannels.filter { $0 != 9 }.map { ch in
                let track = m.notes.first { $0.channel == ch }.flatMap { m.trackNames[$0.track] } ?? ""
                return (ch, "Canale \(ch + 1) · " + (track.isEmpty ? GM.name(m.programs[ch] ?? 0) : track))
            }
            chordSummary = ChordEngine.events(an.regions, midi: m)
            sections = side?.sections ?? SongStructureAnalyzer.analyze(
                SongStructureAnalyzer.input(midi: m, lyrics: lyr, chords: chordSummary, melodyChannel: an.melodyChannel))
            selected = Set(sections.map { $0.id })
            generated = nil
            status = "Tonalità \(KeyDetector.name(root: an.key.root, minor: an.key.minor, notation: AppSettings.shared.notation)) · " +
                "\(chordSummary.count) accordi · \(sections.count) sezioni" + (an.usedFallback ? " · accordi ricavati dalle tracce polifoniche" : "")
        } catch {
            status = error.localizedDescription
        }
    }

    func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["mid", "midi", "kar"].compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK, let u = p.url { open(u) }
    }

    func generate() -> MIDIFile? {
        if let g = generated { return g }
        guard let m = midi, let an = analysis else { return nil }
        let data = PianoArranger(midi: m, regions: an.regions, sections: sections, options: options, bassChannels: an.bassChannels, melodyChannel: melodyChannel).arrange()
        generated = try? MIDIFile(data: data)
        return generated
    }

    func sectionsChanged() { generated = nil; renumber() }

    private func renumber() {
        var c: [SectionKind: Int] = [:]
        for i in sections.indices { c[sections[i].kind, default: 0] += 1; sections[i].number = c[sections[i].kind]! }
    }

    // Anteprima nel lettore principale.
    func togglePreview() {
        let seq = AudioHub.shared.sequencer
        if previewing { seq.pause(); previewing = false; seq.onEnd = savedOnEnd; return }
        guard let g = generate() else { return }
        savedOnEnd = seq.onEnd
        AudioHub.shared.start()
        seq.load(g)
        seq.setTranspose(transpose)
        seq.speed = tempo
        if let first = sections.first(where: { selected.contains($0.id) }), scope != .whole { seq.seek(to: first.start) }
        seq.onEnd = { [weak self] in self?.previewing = false; seq.onEnd = self?.savedOnEnd }
        seq.play()
        previewing = true
    }

    func export() {
        guard let g = generate(), let src = sourceURL else { return }
        let base = src.deletingPathExtension().lastPathComponent + " - Piano"
        if format == .mid {
            let p = NSSavePanel()
            p.nameFieldStringValue = base + ".mid"
            guard p.runModal() == .OK, let u = p.url else { return }
            let data = PianoArranger(midi: midi!, regions: analysis!.regions, sections: sections, options: options, bassChannels: analysis!.bassChannels, melodyChannel: melodyChannel).arrange()
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
        settings.soundBank = AppSettings.shared.soundFontURL
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 12) {
                Panel(title: "Brano MIDI", icon: "pianokeys") {
                    HStack {
                        Text(model.sourceURL?.deletingPathExtension().lastPathComponent ?? "Scegli un MIDI o un KAR (anche dall'archivio, tasto destro → Piano Studio)")
                            .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Button("Apri MIDI…") { model.chooseFile() }.buttonStyle(NeonButtonStyle())
                    }
                    if !model.status.isEmpty { Text(model.status).font(.caption).foregroundColor(Theme.soft) }
                }
                Panel(title: "Struttura riconosciuta — scegli le parti", icon: "rectangle.split.3x1") {
                    if model.sections.isEmpty {
                        Text("Nessun brano caricato").font(.caption).foregroundColor(Theme.soft)
                    } else {
                        if let m = model.midi {
                            SectionStrip(sections: model.sections, duration: m.duration, position: AudioHub.shared.sequencer.position) { _ in }
                                .frame(height: 24)
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
                    Toggle("Semplifica in triadi", isOn: $model.options.simplifyToTriads)
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
                    SoundPickerMenu(player: player)
                    HStack {
                        Button(model.previewing ? "■ Ferma" : "▶ Ascolta") { model.togglePreview() }
                            .buttonStyle(NeonButtonStyle(prominent: false)).disabled(model.midi == nil)
                        Button("Crea \(model.format == .mid ? "MIDI" : "audio")") { model.export() }
                            .buttonStyle(NeonButtonStyle()).disabled(model.midi == nil || model.busy || (model.scope != .whole && model.selected.isEmpty))
                    }
                    if model.busy { ProgressView(value: model.progress).accentColor(Theme.violet) }
                }
            }.frame(width: 340)
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
