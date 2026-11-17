import SwiftUI
import UniformTypeIdentifiers

struct AudioLabView: View {
    @ObservedObject var model: AudioLabModel
    @ObservedObject private var player: PreviewPlayer
    @Environment(\.contentWidth) private var width

    init(model: AudioLabModel) {
        self.model = model
        self._player = ObservedObject(wrappedValue: model.preview)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sourcePanel
            if model.hasSource {
                AdaptiveColumns(width: width, threshold: 980, rightWidth: 380) {
                    VStack(alignment: .leading, spacing: 12) {
                        listenPanel
                        cutPanel
                    }
                } right: {
                    VStack(alignment: .leading, spacing: 12) {
                        partPanel
                        tonePanel
                        exportPanel
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let u = url { DispatchQueue.main.async { model.open(u) } }
            }
            return true
        }
    }

    // MARK: Sorgente

    private var sourcePanel: some View {
        Panel(title: "Audio Lab · da link o file a MP3, WAV e tutti i formati", icon: "waveform") {
            HStack(spacing: 8) {
                TextField("Incolla il link di YouTube (o di un altro sito supportato)", text: $model.link)
                    .textFieldStyle(.roundedBorder).onSubmit { model.downloadLink() }
                Button(action: { model.downloadLink() }) { Label("Scarica audio", systemImage: "arrow.down.circle.fill") }
                    .buttonStyle(NeonButtonStyle()).disabled(model.busy || !model.ytdlpInstalled || model.link.isEmpty)
                Button(action: { model.openFile() }) { Label("Apri file…", systemImage: "folder") }
                    .buttonStyle(NeonButtonStyle(prominent: false)).disabled(model.busy)
            }
            HStack(spacing: 8) {
                if model.ytdlpInstalled {
                    Label("yt-dlp pronto", systemImage: "checkmark.seal.fill").font(.system(size: 11)).foregroundColor(Theme.cyan)
                    Button("Aggiorna yt-dlp") { model.updateYtdlp() }.buttonStyle(.borderless).font(.system(size: 11)).disabled(model.busy)
                } else {
                    Button(action: { model.installYtdlp() }) { Label("Installa yt-dlp (gratis, una volta sola)", systemImage: "square.and.arrow.down") }
                        .buttonStyle(NeonButtonStyle(prominent: false)).disabled(model.busy)
                    Text("Serve per scaricare dai link. I file del Mac si aprono anche senza.").font(.system(size: 11)).foregroundColor(Theme.soft)
                }
                Spacer()
                Text("Oppure trascina qui un brano o un video").font(.system(size: 11)).foregroundColor(Theme.soft)
            }
            if model.busy || !model.status.isEmpty {
                HStack(spacing: 8) {
                    if model.busy { ProgressView(value: model.progress).frame(maxWidth: 220) }
                    Text(model.status).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(2)
                }
            }
            if let e = model.error { Text(e).font(.system(size: 12)).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true) }
            if model.hasSource {
                Text("🎵 \(model.title) · \(formatTime(model.duration))").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.gradient)
            }
            Text("Scarica solo brani tuoi, con licenza libera o di cui hai i diritti: i Termini di YouTube non permettono di scaricare i contenuti di altri senza autorizzazione.")
                .font(.system(size: 10)).foregroundColor(Theme.soft)
        }
    }

    // MARK: Ascolto

    private var listenPanel: some View {
        Panel(title: "Master di ascolto", icon: "headphones") {
            MiniPlayerView(player: player, acceptsDrop: false)
            HStack(spacing: 8) {
                Button(action: { model.makePreview() }) { Label("Ascolta con le modifiche", systemImage: "wand.and.stars") }
                    .buttonStyle(NeonButtonStyle()).disabled(model.busy)
                Button(action: { model.listenOriginal() }) { Label("Originale (confronto)", systemImage: "arrow.left.arrow.right") }
                    .buttonStyle(NeonButtonStyle(prominent: false))
            }
            Text(model.listeningOriginal ? "Stai ascoltando l'originale."
                 : model.previewReady ? "Stai ascoltando il risultato: taglio, voce/base, tono, tempo e mastering, come verrà esportato."
                 : "Ogni modifica prepara da sola una nuova anteprima.")
                .font(.system(size: 11)).foregroundColor(Theme.soft)
        }
    }

    // MARK: Taglio e divisione

    private var cutPanel: some View {
        Panel(title: "Taglio e divisione della traccia", icon: "scissors") {
            let d = max(1, model.duration)
            Text("Inizio: \(formatTime(model.trimStart))").font(.system(size: 12, weight: .semibold))
            Slider(value: Binding(get: { model.trimStart }, set: { model.trimStart = min($0, model.trimEnd - 1) }), in: 0...d)
            Text("Fine: \(formatTime(model.trimEnd))").font(.system(size: 12, weight: .semibold))
            Slider(value: Binding(get: { model.trimEnd }, set: { model.trimEnd = max($0, model.trimStart + 1) }), in: 0...d)
            Toggle("Dissolvenza finale (se tagli prima della fine)", isOn: $model.fadeOut)
            Divider().background(Theme.line)
            Text("Dividi in più file").font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
                Button(action: { model.addCutAtPlayhead() }) { Label("Dividi qui", systemImage: "scissors") }
                    .buttonStyle(NeonButtonStyle(prominent: false)).disabled(!model.previewReady)
                    .help("Aggiunge un punto di divisione dove sei nell'anteprima")
                ForEach([2, 3, 4], id: \.self) { n in
                    Button("In \(n) parti") { model.splitEvenly(n) }.buttonStyle(NeonButtonStyle(prominent: false))
                }
                if !model.cuts.isEmpty { Button("Nessuna divisione") { model.clearCuts() }.buttonStyle(.borderless) }
            }
            if model.cuts.isEmpty {
                Text("Senza divisioni esporti un solo file. Ascolta l'anteprima e premi \"Dividi qui\" nei punti giusti.")
                    .font(.system(size: 11)).foregroundColor(Theme.soft)
            } else {
                FlowLayoutView(items: model.cuts) { t in
                    Chip(text: "✂︎ \(formatTime(t))  ✕", selected: false) { model.removeCut(t) }
                }
                Text("Verranno creati \(model.cuts.count + 1) file. Tocca un punto per toglierlo.").font(.system(size: 11)).foregroundColor(Theme.soft)
            }
        }
    }

    // MARK: Voce e base

    private var partPanel: some View {
        Panel(title: "Voce e base", icon: "person.wave.2") {
            Picker("Esporta", selection: $model.part) {
                ForEach(AudioLabModel.Part.allCases) { p in Text(p.label).tag(p) }
            }.labelsHidden()
            Text(partHelp).font(.system(size: 11)).foregroundColor(Theme.soft).fixedSize(horizontal: false, vertical: true)
            if model.part.needsAI && model.stemNames.isEmpty {
                Button(action: { model.makePreview() }) { Label("Separa con l'AI e ascolta", systemImage: "sparkles") }
                    .buttonStyle(NeonButtonStyle()).disabled(model.busy)
            }
        }
    }

    private var partHelp: String {
        switch model.part {
        case .full: return "Il brano così com'è."
        case .instrumentalQuick: return "Toglie quello che sta al centro dello stereo (di solito la voce) e tiene i bassi. Immediata e gratuita, ma su alcuni brani resta un po' di voce o si perde qualche strumento."
        case .aiInstrumental, .aiVocals, .aiAll:
            return "Separazione di qualità con Demucs su Replicate (chiave in AI Studio, pochi centesimi a brano). Ci vuole circa un minuto; il risultato resta pronto finché non apri un altro brano."
        }
    }

    // MARK: Tono, tempo, mastering

    private var tonePanel: some View {
        Panel(title: "Tonalità, tempo e mastering", icon: "slider.horizontal.3") {
            Stepper(value: $model.semitones, in: -12...12) {
                Text("Trasposizione: " + (model.semitones == 0 ? "originale" : (model.semitones > 0 ? "+\(model.semitones)" : "\(model.semitones)") + " semitoni"))
                    .font(.system(size: 12, weight: .semibold))
            }
            Text("Tempo: \(Int((model.tempo * 100).rounded()))%").font(.system(size: 12, weight: .semibold))
            Slider(value: $model.tempo, in: 0.75...1.25, step: 0.01)
            Picker("Mastering", selection: $model.master) {
                ForEach(AudioLabModel.MasterMode.allCases) { m in Text(m.label).tag(m) }
            }
            Toggle("Equalizzazione (bassi puliti, voci più chiare)", isOn: $model.eq).disabled(model.master == .off)
            Text("La trasposizione cambia la tonalità senza cambiare la velocità, e il tempo senza cambiare la tonalità.")
                .font(.system(size: 10)).foregroundColor(Theme.soft)
        }
    }

    // MARK: Esportazione

    private var exportPanel: some View {
        Panel(title: "Esporta", icon: "square.and.arrow.up") {
            FlowLayoutView(items: AudioLabFormat.allCases) { f in
                Chip(text: f.label, selected: model.formats.contains(f)) {
                    if model.formats.contains(f) { model.formats.remove(f) } else { model.formats.insert(f) }
                }
            }
            HStack {
                Text("Cartella: \(model.outputFolder.lastPathComponent)").font(.system(size: 11)).foregroundColor(Theme.soft).lineLimit(1)
                Button("Cambia…") { model.chooseFolder() }.buttonStyle(.borderless).font(.system(size: 11))
            }
            Button(action: { model.export() }) { Label("Esporta \(model.formats.count) format\(model.formats.count == 1 ? "o" : "i")", systemImage: "square.and.arrow.up.fill") }
                .buttonStyle(NeonButtonStyle()).disabled(model.busy || model.formats.isEmpty)
            if !model.exported.isEmpty {
                Button(action: { model.revealExported() }) { Label("Mostra i \(model.exported.count) file nel Finder", systemImage: "folder") }
                    .buttonStyle(NeonButtonStyle(prominent: false))
            }
        }
    }
}
