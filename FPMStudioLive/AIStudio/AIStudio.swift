import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// AI Studio: procedura guidata in 5 passi, gratuita e illimitata (tutto calcolato sul Mac).
final class AIStudioModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case source, vocal, style, lyrics, summary
        var id: Int { rawValue }
        var label: String {
            switch self {
            case .source: return "Sorgente e durata"
            case .vocal: return "Voce o strumentale"
            case .style: return "Stile e musica"
            case .lyrics: return "Testi"
            case .summary: return "Riepilogo"
            }
        }
        var icon: String {
            switch self {
            case .source: return "doc.badge.plus"
            case .vocal: return "mic"
            case .style: return "paintpalette"
            case .lyrics: return "text.alignleft"
            case .summary: return "list.bullet.rectangle"
            }
        }
    }

    @Published var step: Step = .source
    @Published var req = GeneratorRequest()
    @Published var referenceURL: URL?
    @Published private(set) var reference: ReferenceTrack?
    @Published private(set) var referenceInfo = ""
    @Published private(set) var analyzingReference = false
    @Published var autoBPM = true
    @Published var manualBPM: Double = 110
    @Published var studioQuality = true
    @Published var showAdvanced = false
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var result: GeneratedSong?
    @Published private(set) var resultURL: URL?
    @Published var status = ""
    @Published private(set) var history: [URL] = []
    /// Lettore dedicato dell'AI Studio (non usa il karaoke).
    let preview = PreviewPlayer()
    @Published var prepareForSuno = UserDefaults.standard.bool(forKey: "prepareForSuno") { didSet { UserDefaults.standard.set(prepareForSuno, forKey: "prepareForSuno") } }

    /// Ascolta un brano creato (MIDI → audio con i suoni scelti) nel lettore dell'AI Studio.
    func listen(_ u: URL) {
        guard let m = try? MIDIFile(url: u) else { preview.load(u, autoplay: true); return }
        var s = OfflineRenderer.Settings()
        s.soundBank = AppSettings.shared.soundFontURL
        s.sampleRate = 44100
        preview.loadMIDI(m, key: "ai|\(u.path)|\((try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0)|\(s.soundBank?.path ?? "")",
                         title: u.deletingPathExtension().lastPathComponent, settings: s, autoplay: true)
    }

    // MARK: Suno
    /// Suno non offre un collegamento ufficiale per altre app: preparo stile e testo pronti da incollare in suno.com.
    var sunoStyle: String {
        var parts = resolvedStyles.map { $0.label }
        if !req.styleText.isEmpty { parts.append(req.styleText) }
        if let r = result { parts.append("\(Int(r.bpm.rounded())) BPM"); parts.append(KeyDetector.name(root: r.keyRoot, minor: r.minor, notation: .english)) }
        else if !autoBPM { parts.append("\(Int(manualBPM)) BPM") }
        if req.vocal == .instrumental { parts.append("instrumental") }
        var s = parts.joined(separator: ", ")
        if !req.negativeText.isEmpty { s += " — senza: " + req.negativeText }
        return String(s.prefix(1000))
    }

    var sunoLyrics: String {
        let paragraphs = SongGenerator.paragraphs(req.lyrics)
        guard !paragraphs.isEmpty else { return req.vocal == .instrumental ? "[Instrumental]" : "" }
        var seen: [String: Int] = [:]
        for p in paragraphs { seen[p.text.joined(separator: "\n").lowercased(), default: 0] += 1 }
        var out: [String] = ["[Intro]"]
        for p in paragraphs {
            let k = p.text.joined(separator: "\n").lowercased()
            let tag: String
            switch p.label ?? ((seen[k] ?? 0) > 1 ? .chorus : .verse) {
            case .chorus: tag = "[Chorus]"
            case .bridge: tag = "[Bridge]"
            case .preChorus: tag = "[Pre-Chorus]"
            case .intro: tag = "[Intro]"
            case .outro: tag = "[Outro]"
            default: tag = "[Verse]"
            }
            out.append(tag); out += p.text; out.append("")
        }
        out.append("[Outro]")
        return out.joined(separator: "\n")
    }

    func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        status = "Copiato: incollalo in Suno"
    }

    static let styleTags: [String] = ["Pop", "Rock", "R&B", "Hip-Hop", "Dance", "EDM", "House", "Techno", "Trap", "Lo-fi", "Chillout", "Synthwave",
                                      "Jazz", "Classical", "Piano Ballad", "Acoustic", "Country", "Folk", "Metal", "Soul", "Gospel", "Latin",
                                      "Reggaeton", "Cinematic", "Bossa Nova", "Valzer", "Liscio", "Funk"]
    static let negativeTags: [String] = ["Batteria", "Basso", "Pianoforte", "Chitarra", "Archi", "Synth", "Fiati"]
    static let durations: [(String, Double)] = [("Auto", 0), ("Reels (15s)", 15), ("Breve (30s)", 30), ("1 Minuto", 60), ("2 Minuti", 120), ("3 Minuti", 180)]

    var folder: URL {
        let u = AppPaths.exports.appendingPathComponent("AI Studio", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    init() {
        req.seed = UInt64(Date().timeIntervalSince1970)
        refreshHistory()
    }

    func refreshHistory() {
        history = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "mid" }
            .sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
    }

    // MARK: Stile

    func toggleStyleTag(_ t: String) {
        var parts = req.styleText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let i = parts.firstIndex(where: { $0.lowercased() == t.lowercased() }) { parts.remove(at: i) } else { parts.append(t) }
        req.styleText = String(parts.joined(separator: ", ").prefix(1000))
    }
    func styleTagSelected(_ t: String) -> Bool { req.styleText.lowercased().contains(t.lowercased()) }

    func toggleNegative(_ t: String) {
        var parts = req.negativeText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let i = parts.firstIndex(where: { $0.lowercased() == t.lowercased() }) { parts.remove(at: i) } else { parts.append(t) }
        req.negativeText = parts.joined(separator: ", ")
    }
    func negativeSelected(_ t: String) -> Bool { req.negativeText.lowercased().contains(t.lowercased()) }

    var resolvedStyles: [MusicStyle] {
        let s = MusicStyle.fromText(req.styleText)
        return s.isEmpty ? [.pop] : s
    }

    // MARK: Traccia di riferimento

    func chooseReference() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["mid", "midi", "kar", "mp3", "m4a", "wav", "aif", "aiff"].compactMap { UTType(filenameExtension: $0) }
        if p.runModal() == .OK, let u = p.url { setReference(u) }
    }

    func setReference(_ url: URL) {
        referenceURL = url
        req.source = .reference
        analyzingReference = true
        referenceInfo = "Analizzo \(url.lastPathComponent)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let ref = Self.buildReference(url)
            DispatchQueue.main.async {
                self.analyzingReference = false
                self.reference = ref
                if let r = ref {
                    self.referenceInfo = "\(Int(r.bpm.rounded())) BPM · \(KeyDetector.name(root: r.keyRoot, minor: r.minor, notation: AppSettings.shared.notation)) · " +
                        "\(formatTime(r.duration)) · " + r.sections.map { $0.title }.joined(separator: " ")
                    if self.req.lyrics.isEmpty, let l = r.lyrics, !l.isEmpty {
                        self.req.lyrics = l.lines.map { line in line.text + (line.endsParagraph ? "\n" : "") }.joined(separator: "\n")
                    }
                } else {
                    self.referenceInfo = "Non riesco ad analizzare questo file."
                }
            }
        }
    }

    static func buildReference(_ url: URL) -> ReferenceTrack? {
        if SongKind.of(url) == .midi {
            guard let m = try? MIDIFile(url: url) else { return nil }
            let lyr = SongSidecar.load(for: url)?.lyrics ?? m.karaokeLyrics()
            let an = ChordEngine.analyze(m, lyrics: lyr)
            let evs = ChordEngine.events(an.regions, midi: m)
            let input = SongStructureAnalyzer.input(midi: m, lyrics: lyr, chords: evs, melodyChannel: an.melodyChannel)
            let sections = SongStructureAnalyzer.analyze(input)
            let barChords: [Chord?] = input.bars.map { t in evs.last(where: { $0.time <= t + 0.2 })?.chord }
            return ReferenceTrack(bpm: m.mainBPM, beatsPerBar: m.mainTimeSignature.num == 6 ? 2 : m.mainTimeSignature.num, keyRoot: an.key.root,
                                  minor: an.key.minor, duration: m.duration, barChords: barChords, sections: sections, lyrics: lyr.isEmpty ? nil : lyr)
        }
        guard let r = try? AudioAnalyzer.analyze(url: url) else { return nil }
        let bars = r.bars
        let side = SongSidecar.load(for: url)
        let input = SongStructureAnalyzer.Input(bars: bars, duration: r.duration, musicStart: r.leadIn, lyrics: side?.lyrics,
                                                chords: r.chords, vocalTimes: [], density: r.barEnergy)
        let sections = SongStructureAnalyzer.analyze(input)
        let barChords: [Chord?] = bars.map { t in r.chords.last(where: { $0.time <= t + 0.15 })?.chord }
        return ReferenceTrack(bpm: r.bpm, beatsPerBar: 4, keyRoot: r.keyRoot, minor: r.keyMinor, duration: r.duration,
                              barChords: barChords, sections: sections, lyrics: side?.lyrics)
    }

    // MARK: Generazione

    func generate(newVariant: Bool = false) {
        if newVariant { req.seed = req.seed &+ 7919 }
        var r = req
        r.styles = resolvedStyles
        r.bpm = autoBPM ? nil : manualBPM
        let ref = r.source == .reference ? reference : nil
        busy = true; progress = 0.05; status = "Compongo…"
        DispatchQueue.global(qos: .userInitiated).async {
            let song = SongGenerator(req: r, reference: ref).generate()
            let title = r.title.isEmpty ? "AI Studio \(Self.stamp())" : r.title
            let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
            let url = self.folder.appendingPathComponent(safe + ".mid")
            do {
                try song.midi.write(to: url, options: .atomic)
                var side = SongSidecar()
                side.lyrics = song.lyrics.isEmpty ? nil : song.lyrics
                side.chords = song.chords
                side.sections = song.sections
                side.melodyChannel = r.vocal == .guideMelody ? 7 : nil
                try side.save(for: url)
            } catch {
                DispatchQueue.main.async { self.busy = false; self.status = error.localizedDescription }
                return
            }
            DispatchQueue.main.async {
                self.result = song
                self.resultURL = url
                self.busy = false
                self.progress = 1
                self.status = "Creato: \(url.lastPathComponent)"
                self.refreshHistory()
            }
        }
    }

    func exportAudio(format: ExportFormat) {
        guard let url = resultURL, let song = result, let m = try? MIDIFile(data: song.midi) else { return }
        var s = OfflineRenderer.Settings()
        s.soundBank = AppSettings.shared.soundFontURL
        s.sampleRate = studioQuality ? 48000 : 44100
        s.reverb = studioQuality ? 16 : 10
        busy = true; progress = 0; status = "Genero l'audio…"
        let studio = studioQuality
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var a = try OfflineRenderer.render(m, settings: s) { p in DispatchQueue.main.async { self.progress = p * 0.8 } }
                Mastering.master(&a.left, &a.right, sr: a.sampleRate, mode: studio ? .pro : .natural, applyEQ: false)
                let out = url.deletingPathExtension().appendingPathExtension(format.rawValue)
                try AudioExporter.write(a, to: out, format: format) { p in DispatchQueue.main.async { self.progress = 0.8 + p * 0.2 } }
                DispatchQueue.main.async {
                    self.busy = false; self.status = "Salvato \(out.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.status = error.localizedDescription }
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "dd-MM HH.mm"; return f.string(from: Date())
    }

    func reset() {
        let seed = req.seed
        req = GeneratorRequest(); req.seed = seed &+ 1
        referenceURL = nil; reference = nil; referenceInfo = ""; result = nil; resultURL = nil; step = .source; status = ""
    }
}

private extension URL {
    var modificationDate: Date? { (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
}

struct AIStudioView: View {
    @ObservedObject var model: AIStudioModel
    @ObservedObject var player: KaraokePlayer
    @ObservedObject var library: Library
    var openKaraoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                Panel(title: "Info progetto", icon: "info.circle") {
                    Text("TITOLO PROGETTO").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.soft)
                    TextField("Inserisci titolo progetto…", text: $model.req.title).textFieldStyle(.roundedBorder)
                    Text("TAG").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.soft)
                    TextField("es. Pop, Demo, Serata sabato", text: $model.req.tags).textFieldStyle(.roundedBorder)
                }
                Panel(title: "Parametri", icon: "cpu") {
                    ForEach(AIStudioModel.Step.allCases) { s in
                        Button(action: { model.step = s }) {
                            HStack {
                                Image(systemName: s.rawValue < model.step.rawValue ? "checkmark.circle.fill" : s.icon)
                                    .foregroundColor(s.rawValue < model.step.rawValue ? Theme.cyan : Theme.soft)
                                Text(s.label).foregroundColor(model.step == s ? .white : Theme.soft)
                                Spacer()
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(model.step == s ? Theme.violet.opacity(0.35) : Color.clear))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.step == s ? Theme.violet : Color.clear))
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    Image(systemName: "infinity")
                    Text("GRATIS · illimitato · offline").font(.system(size: 12, weight: .heavy))
                }
                .frame(maxWidth: .infinity).padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.gradient).opacity(0.35))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.violet))
                MiniPlayerView(player: model.preview)
                Panel(title: "I miei brani", icon: "music.note.list") {
                    if model.history.isEmpty { Text("Ancora nessuno").font(.caption).foregroundColor(Theme.soft) }
                    ForEach(model.history.prefix(8), id: \.self) { u in
                        HStack {
                            Button(action: { model.listen(u) }) {
                                HStack { Image(systemName: "play.circle"); Text(u.deletingPathExtension().lastPathComponent).lineLimit(1); Spacer() }
                            }.buttonStyle(.plain).font(.caption)
                            Button(action: { player.load(LibraryItem(url: u), autoplay: true); openKaraoke() }) { Image(systemName: "music.mic") }
                                .buttonStyle(.plain).help("Apri nel karaoke")
                        }
                    }
                }
            }.frame(width: 250)

            VStack(alignment: .leading, spacing: 12) {
                Panel(title: model.step.label, icon: model.step.icon) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) { stepContent }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Button(action: { model.reset() }) { Label("Annulla", systemImage: "xmark") }.buttonStyle(NeonButtonStyle(prominent: false))
                    Button(action: { if let p = AIStudioModel.Step(rawValue: model.step.rawValue - 1) { model.step = p } }) {
                        Label("Indietro", systemImage: "arrow.left")
                    }.buttonStyle(NeonButtonStyle(prominent: false)).disabled(model.step == .source)
                    Spacer()
                    if model.busy { ProgressView(value: model.progress).frame(width: 160) }
                    Text(model.status).font(.caption).foregroundColor(Theme.cyan).lineLimit(1)
                    if model.step == .summary {
                        Button(action: { model.generate() }) { Label("Crea il brano", systemImage: "wand.and.stars") }
                            .buttonStyle(NeonButtonStyle()).disabled(model.busy || model.analyzingReference)
                    } else {
                        Button(action: { if let n = AIStudioModel.Step(rawValue: model.step.rawValue + 1) { model.step = n } }) {
                            Label("Avanti", systemImage: "arrow.right")
                        }.buttonStyle(NeonButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .source: sourceStep
        case .vocal: vocalStep
        case .style: styleStep
        case .lyrics: lyricsStep
        case .summary: summaryStep
        }
    }

    private func bigChoice(_ icon: String, _ title: String, _ subtitle: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.system(size: 13, weight: .bold))
                Text(subtitle).font(.system(size: 11)).foregroundColor(Theme.soft).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 90).padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.violet.opacity(0.3) : Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.magenta : Theme.line))
        }.buttonStyle(.plain)
    }

    private var sourceStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                bigChoice("music.note", "Ho una traccia", "MIDI o MP3: trascinalo qui. Tengo accordi, tempo, struttura e testo e lo riarrangio nello stile scelto.",
                          model.req.source == .reference) { model.req.source = .reference }
                    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                        DropHelper.urls(from: providers) { urls in if let u = urls.first(where: { SongKind.of($0) != nil }) { model.setReference(u) } }
                        return true
                    }
                bigChoice("sparkles", "Da zero", "Compongo un brano nuovo dal tuo testo e dallo stile.", model.req.source == .scratch) { model.req.source = .scratch }
            }
            if model.req.source == .reference {
                VStack(spacing: 10) {
                    Image(systemName: "icloud.and.arrow.up").font(.system(size: 30)).foregroundColor(Theme.cyan)
                    HStack {
                        Button("Scegli file") { model.chooseReference() }.buttonStyle(NeonButtonStyle(prominent: false))
                        Text(model.referenceURL?.lastPathComponent ?? "oppure trascina qui il file").foregroundColor(Theme.soft)
                    }
                    if model.analyzingReference { ProgressView() }
                    if !model.referenceInfo.isEmpty { Text(model.referenceInfo).font(.caption).foregroundColor(Theme.cyan) }
                    Text("Il file resta sul tuo Mac: niente caricamenti online, niente crediti.").font(.caption).foregroundColor(Theme.soft)
                }
                .frame(maxWidth: .infinity).padding(16)
                .background(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [5])))
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let u = url { DispatchQueue.main.async { model.setReference(u) } }
                    }
                    return true
                }
                Text("Usa brani di cui hai i diritti o per uso personale: la nuova base è un tuo arrangiamento.")
                    .font(.caption).foregroundColor(Theme.warn)
            }
            Text("DURATA").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.soft)
            HStack {
                ForEach(AIStudioModel.durations, id: \.0) { d in
                    Chip(text: d.1 == 0 && model.req.source == .reference ? "Come l'originale" : d.0, selected: model.req.duration == d.1) { model.req.duration = d.1 }
                }
            }
            Text(model.req.source == .reference ? "Con una traccia la struttura viene accorciata per stare nella durata." :
                    "Con un testo, \"Auto\" adatta la durata alle strofe.").font(.caption).foregroundColor(Theme.soft)
        }
    }

    private var vocalStep: some View {
        HStack(spacing: 12) {
            bigChoice("music.mic", "Melodia guida", "Uno strumento suona la melodia del testo, sillaba per sillaba, sincronizzata al karaoke.",
                      model.req.vocal == .guideMelody) { model.req.vocal = .guideMelody }
            bigChoice("nosign", "Strumentale", "Solo base: il testo (se c'è) compare comunque a schermo.", model.req.vocal == .instrumental) { model.req.vocal = .instrumental }
        }
    }

    private var styleStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("STILE").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.soft)
            TextEditor(text: $model.req.styleText).frame(height: 70)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
            FlowLayoutView(items: AIStudioModel.styleTags) { t in Chip(text: t, selected: model.styleTagSelected(t)) { model.toggleStyleTag(t) } }
            Text("Stile riconosciuto: " + model.resolvedStyles.map { $0.label }.joined(separator: ", ") + " · max 1000 caratteri").font(.caption).foregroundColor(Theme.soft)
            Text("VELOCITÀ (BPM)").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.soft)
            HStack {
                Chip(text: "AUTO", selected: model.autoBPM) { model.autoBPM.toggle() }
                Slider(value: $model.manualBPM, in: 50...200, step: 1).disabled(model.autoBPM)
            }
            Text(model.autoBPM ? "\(Int(model.reference?.bpm ?? model.resolvedStyles[0].defaultBPM)) BPM · Automatico" : "\(Int(model.manualBPM)) BPM")
                .font(.caption).foregroundColor(Theme.soft)
            HStack(alignment: .top, spacing: 12) {
                Panel(title: "Varietà stile") {
                    Picker("", selection: $model.req.variety) { Text("Bassa").tag(0); Text("Normale").tag(1); Text("Alta").tag(2) }.labelsHidden()
                    Text("Quanto il risultato varia dallo stile scelto.").font(.caption).foregroundColor(Theme.soft)
                }
                Panel(title: "Qualità Studio") {
                    Toggle("Audio 48 kHz, mastering -14 LUFS", isOn: $model.studioQuality).toggleStyle(.switch)
                    Text("Gratis, nessun credito extra.").font(.caption).foregroundColor(Theme.cyan)
                }
            }
            Text("TONALITÀ").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.soft)
            HStack {
                Picker("Nota", selection: Binding(get: { model.req.keyRoot ?? -1 }, set: { model.req.keyRoot = $0 < 0 ? nil : $0 })) {
                    Text("Automatica").tag(-1)
                    ForEach(0..<12, id: \.self) { k in Text(Chord.noteName(k, notation: AppSettings.shared.notation, preferFlats: Chord.defaultPrefersFlat(k))).tag(k) }
                }.frame(width: 200)
                Picker("", selection: Binding(get: { model.req.minor.map { $0 ? 1 : 0 } ?? -1 }, set: { model.req.minor = $0 < 0 ? nil : $0 == 1 })) {
                    Text("Automatico").tag(-1); Text("Maggiore").tag(0); Text("Minore").tag(1)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            Button(action: { withAnimation { model.showAdvanced.toggle() } }) { Label("Opzioni avanzate", systemImage: "slider.horizontal.3") }
                .buttonStyle(NeonButtonStyle(prominent: false))
            if model.showAdvanced {
                Panel(title: "Avanzate", icon: "slider.horizontal.3") {
                    Text("TAG NEGATIVI").font(.system(size: 11, weight: .bold)).foregroundColor(Theme.soft)
                    TextField("Strumenti da escludere, es. batteria, archi", text: $model.req.negativeText).textFieldStyle(.roundedBorder)
                    FlowLayoutView(items: AIStudioModel.negativeTags) { t in Chip(text: t, selected: model.negativeSelected(t)) { model.toggleNegative(t) } }
                    HStack(alignment: .top, spacing: 16) {
                        weight("PESO STILE", $model.req.styleWeight, "Quanto lo stile caratterizza ritmo e swing.")
                        weight("STRANEZZA", $model.req.strangeness, "0 prevedibile · 1 armonie sperimentali.")
                        weight("PESO AUDIO", $model.req.referenceWeight, "0 accordi nuovi · 1 accordi del riferimento.")
                    }
                }
            }
        }
    }

    private func weight(_ t: String, _ v: Binding<Double>, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(t).font(.system(size: 10, weight: .bold)); Text(String(format: "%.2f", v.wrappedValue)).font(.system(size: 10, weight: .bold)).foregroundColor(Theme.magenta) }
            Slider(value: v, in: 0...1).accentColor(Theme.magenta)
            Text(help).font(.system(size: 10)).foregroundColor(Theme.soft)
        }
    }

    private var lyricsStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Scrivi il testo: una riga per verso, riga vuota tra le strofe. Le strofe ripetute diventano il ritornello; puoi anche scrivere [Ritornello], [Strofa], [Bridge].")
                .font(.caption).foregroundColor(Theme.soft)
            TextEditor(text: $model.req.lyrics).font(.system(size: 14)).frame(minHeight: 300)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
            let p = SongGenerator.paragraphs(model.req.lyrics)
            Text("\(p.count) strofe · \(p.reduce(0) { $0 + $1.text.count }) versi").font(.caption).foregroundColor(Theme.cyan)
        }
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            let r = model.req
            summaryRow("Titolo", r.title.isEmpty ? "(automatico)" : r.title)
            summaryRow("Sorgente", r.source == .reference ? "Traccia: \(model.referenceURL?.lastPathComponent ?? "nessuna")" : "Da zero")
            summaryRow("Durata", r.duration == 0 ? "Automatica" : formatTime(r.duration))
            summaryRow("Voce", r.vocal == .guideMelody ? "Melodia guida" : "Strumentale")
            summaryRow("Stile", model.resolvedStyles.map { $0.label }.joined(separator: ", ") + (model.autoBPM ? " · BPM auto" : " · \(Int(model.manualBPM)) BPM"))
            if !r.negativeText.isEmpty { summaryRow("Senza", r.negativeText) }
            summaryRow("Testo", r.lyrics.isEmpty ? "nessuno" : "\(SongGenerator.paragraphs(r.lyrics).count) strofe")
            summaryRow("Suoni", AppSettings.shared.soundFontName)
            Toggle("Prepara anche per Suno (stile e testo pronti da incollare nel tuo account)", isOn: $model.prepareForSuno).toggleStyle(.checkbox)
            if model.prepareForSuno {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suno non permette ad altre app di creare brani nel tuo account: preparo tutto io, tu incolli e premi Create.")
                        .font(.caption).foregroundColor(Theme.soft).fixedSize(horizontal: false, vertical: true)
                    Text("STILE").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.soft)
                    Text(model.sunoStyle).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    Text("TESTO CON SEZIONI").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.soft)
                    ScrollView { Text(model.sunoLyrics).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 110)
                    HStack {
                        Button("Copia stile") { model.copyToPasteboard(model.sunoStyle) }.buttonStyle(NeonButtonStyle(prominent: false))
                        Button("Copia testo") { model.copyToPasteboard(model.sunoLyrics) }.buttonStyle(NeonButtonStyle(prominent: false))
                        Button("Copia titolo") { model.copyToPasteboard(model.req.title) }.buttonStyle(NeonButtonStyle(prominent: false))
                        Button("Apri Suno") { NSWorkspace.shared.open(URL(string: "https://suno.com/create")!) }.buttonStyle(NeonButtonStyle())
                    }
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            }
            if let song = model.result {
                Divider()
                Text(song.summary).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.cyan)
                SectionStrip(sections: song.sections, duration: song.sections.last?.end ?? 1, position: 0) { _ in }.frame(height: 22)
                HStack {
                    Button("▶ Ascolta") { if let u = model.resultURL { model.listen(u) } }.buttonStyle(NeonButtonStyle())
                    Button("Apri nel Karaoke") {
                        if let u = model.resultURL { player.load(LibraryItem(url: u), autoplay: false); openKaraoke() }
                    }.buttonStyle(NeonButtonStyle(prominent: false))
                    Button("Nuova variante") { model.generate(newVariant: true) }.buttonStyle(NeonButtonStyle(prominent: false))
                    Button("MP3") { model.exportAudio(format: .mp3) }.buttonStyle(NeonButtonStyle(prominent: false))
                    Button("WAV") { model.exportAudio(format: .wav) }.buttonStyle(NeonButtonStyle(prominent: false))
                    Button("Aggiungi alla scaletta") { if let u = model.resultURL { library.addFiles([u]); library.enqueue(LibraryItem(url: u)) } }
                        .buttonStyle(NeonButtonStyle(prominent: false))
                }
            }
        }
    }

    private func summaryRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k.uppercased()).font(.system(size: 10, weight: .bold)).foregroundColor(Theme.soft).frame(width: 90, alignment: .leading)
            Text(v).font(.system(size: 13))
        }
    }
}
