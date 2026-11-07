import Foundation
import AppKit
import SwiftUI

/// Catalogo dei suoni professionali per le basi MIDI.
/// - Gratuiti con licenza che ne consente l'uso: scaricabili con un clic dal sito ufficiale dell'autore.
/// - Commerciali: indicati con il link al produttore (non si possono includere nell'app).
struct SoundFontOffer: Identifiable {
    var id: String
    var name: String
    var detail: String
    var size: String
    var license: String
    var downloadURLs: [URL]          // vuoto = solo pagina del produttore
    var page: URL
    var fileName: String
    /// File diviso in parti (da riunire nell'ordine): usato per i SoundFont pubblicati nel repository dell'app.
    var parts: [URL] = []
}

final class SoundFontStore: ObservableObject {
    static let offers: [SoundFontOffer] = [
        SoundFontOffer(id: "sc-va", name: "Roland Sound Canvas VA (consigliato)",
                       detail: "Il modulo GS originale Roland su cui sono programmate quasi tutte le basi MIDI karaoke. Plugin Audio Unit: dopo l'installazione sceglilo in \"Strumento professionale\".",
                       size: "—", license: "Commerciale (Roland Cloud)", downloadURLs: [],
                       page: URL(string: "https://www.roland.com/global/products/rc_sound_canvas_va/")!, fileName: ""),
        SoundFontOffer(id: "msgl", name: "MuseScore General Lite",
                       detail: "Il secondo banco della tua app \"Basi per il coro\", convertito per il Mac: archi, fiati e pianoforti molto naturali. 311 suoni GM/GS.",
                       size: "≈ 216 MB", license: "Gratuito (licenza MIT)", downloadURLs: [],
                       page: URL(string: "https://github.com/francescopaolomorelli76-lang/fpm-studio-live/tree/main/soundfonts")!,
                       fileName: "MuseScore_General_Lite.sf2",
                       parts: (0...2).map { URL(string: "https://raw.githubusercontent.com/francescopaolomorelli76-lang/fpm-studio-live/main/soundfonts/MuseScore_General_Lite.sf2.part\($0)")! }),
        SoundFontOffer(id: "generaluser", name: "GeneralUser GS 2.0.3 (incluso nell'app)",
                       detail: "SoundFont GM/GS curatissimo e leggero, ottimo bilanciamento tra gli strumenti: ideale per un Mac Intel.",
                       size: "≈ 30 MB", license: "Gratuito, anche per uso commerciale (S. Christian Collins)",
                       downloadURLs: [URL(string: "https://github.com/mrbumpy409/GeneralUser-GS/raw/main/GeneralUser-GS.sf2")!],
                       page: URL(string: "https://schristiancollins.com/generaluser.php")!, fileName: "GeneralUser-GS.sf2"),
        SoundFontOffer(id: "musescore", name: "MuseScore General",
                       detail: "SoundFont GM completo con pianoforti e archi di alta qualità.",
                       size: "≈ 210 MB", license: "Gratuito (licenza MIT)",
                       downloadURLs: [URL(string: "https://ftp.osuosl.org/pub/musescore/soundfont/MuseScore_General/MuseScore_General.sf2")!],
                       page: URL(string: "https://musescore.org/en/handbook/3/soundfonts-and-sfz-files")!, fileName: "MuseScore_General.sf2"),
        SoundFontOffer(id: "toh", name: "Timbres of Heaven",
                       detail: "SoundFont GM/GS molto ricco (batterie, chitarre, fiati), tra i più apprezzati per i MIDI karaoke. Pesante: meglio sull'M1.",
                       size: "≈ 400 MB", license: "Gratuito per uso personale (Don Allen)", downloadURLs: [],
                       page: URL(string: "https://midkar.com/soundfonts/")!, fileName: "")
    ]

    @Published private(set) var downloading: String?
    @Published private(set) var progress = 0.0
    @Published var message = ""
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    var folder: URL {
        let u = AppPaths.support.appendingPathComponent("SoundFont", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func installedURL(_ o: SoundFontOffer) -> URL? {
        if o.id == "generaluser", let b = AppSettings.bundledSoundFont { return b }   // già incluso nell'app
        guard !o.fileName.isEmpty else { return nil }
        let u = folder.appendingPathComponent(o.fileName)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Scarica e, a download finito, attiva il SoundFont.
    func download(_ o: SoundFontOffer, urls: [URL]? = nil, activate: @escaping (URL) -> Void) {
        if !o.parts.isEmpty && urls == nil { downloadParts(o, activate: activate); return }
        var list = urls ?? o.downloadURLs
        guard !list.isEmpty else { NSWorkspace.shared.open(o.page); return }
        let url = list.removeFirst()
        downloading = o.id
        progress = 0
        message = "Scarico \(o.name)…"
        let dest = folder.appendingPathComponent(o.fileName)
        task = URLSession.shared.downloadTask(with: url) { [weak self] tmp, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                if let tmp = tmp, ok, Self.looksLikeSoundFont(tmp) {
                    try? FileManager.default.removeItem(at: dest)
                    do {
                        try FileManager.default.moveItem(at: tmp, to: dest)
                        self.downloading = nil
                        self.message = "\(o.name) installato e attivato"
                        activate(dest)
                    } catch {
                        self.downloading = nil
                        self.message = "Non riesco a salvare il file: \(error.localizedDescription)"
                    }
                } else if !list.isEmpty {
                    self.download(o, urls: list, activate: activate)
                } else {
                    self.downloading = nil
                    self.message = "Download non riuscito (\(err?.localizedDescription ?? "link non disponibile")). Ti apro la pagina ufficiale: scaricalo da lì e scegli il file con \"Scegli .sf2…\"."
                    NSWorkspace.shared.open(o.page)
                }
            }
        }
        observation = task?.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.progress = p.fractionCompleted }
        }
        task?.resume()
    }

    /// Scarica le parti una dopo l'altra e le riunisce in un unico SoundFont.
    private func downloadParts(_ o: SoundFontOffer, index: Int = 0, activate: @escaping (URL) -> Void) {
        let dest = folder.appendingPathComponent(o.fileName)
        let partial = folder.appendingPathComponent(o.fileName + ".download")
        if index == 0 {
            try? FileManager.default.removeItem(at: partial)
            FileManager.default.createFile(atPath: partial.path, contents: nil)
            downloading = o.id
            message = "Scarico \(o.name)…"
        }
        guard index < o.parts.count else {
            guard Self.looksLikeSoundFont(partial) else {
                downloading = nil; message = "Il file scaricato non è valido, riprova."; return
            }
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.moveItem(at: partial, to: dest) } catch { downloading = nil; message = error.localizedDescription; return }
            downloading = nil
            message = "\(o.name) installato e attivato"
            activate(dest)
            return
        }
        task = URLSession.shared.downloadTask(with: o.parts[index]) { [weak self] tmp, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                guard let tmp = tmp, ok, let data = try? Data(contentsOf: tmp, options: .mappedIfSafe),
                      let h = try? FileHandle(forWritingTo: partial) else {
                    self.downloading = nil
                    self.message = "Download non riuscito (\(err?.localizedDescription ?? "parte \(index + 1) non disponibile")). Controlla la connessione e riprova."
                    return
                }
                h.seekToEndOfFile(); h.write(data); try? h.close()
                self.downloadParts(o, index: index + 1, activate: activate)
            }
        }
        observation = task?.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.progress = (Double(index) + p.fractionCompleted) / Double(o.parts.count) }
        }
        task?.resume()
    }

    func cancel() { task?.cancel(); downloading = nil; message = "Download annullato" }

    /// Controllo che sia davvero un SoundFont (intestazione RIFF…sfbk) e non una pagina web.
    static func looksLikeSoundFont(_ u: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? h.close() }
        let d = h.readData(ofLength: 12)
        return d.count == 12 && d.prefix(4) == Data("RIFF".utf8) && d.suffix(4) == Data("sfbk".utf8)
    }
}

struct SoundFontStoreView: View {
    @ObservedObject var store: SoundFontStore
    var activate: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(SoundFontStore.offers) { o in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.name).bold()
                        Text(o.detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("\(o.size) · \(o.license)").font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    if let u = store.installedURL(o) {
                        Button("Usa") { activate(u) }
                    } else if o.downloadURLs.isEmpty && o.parts.isEmpty {
                        Button("Sito ufficiale") { NSWorkspace.shared.open(o.page) }
                    } else if store.downloading == o.id {
                        ProgressView(value: store.progress).frame(width: 90)
                        Button("Annulla") { store.cancel() }
                    } else {
                        Button("Scarica e usa") { store.download(o, activate: activate) }.disabled(store.downloading != nil)
                    }
                }
                Divider()
            }
            if !store.message.isEmpty { Text(store.message).font(.caption).foregroundColor(.accentColor).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Menu rapido "Suoni": cambia il banco delle basi MIDI con un clic (SoundFont inclusi, scaricati, personali, plugin).
struct SoundPickerMenu: View {
    @ObservedObject var settings = AppSettings.shared
    var player: KaraokePlayer
    @StateObject private var store = SoundFontStore()

    private var downloaded: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: store.folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["sf2", "dls"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var body: some View {
        Menu {
            Section(header: Text("Inclusi")) {
                Button(check("") + "GeneralUser GS (incluso)") { use("") }
                Button(check(AppSettings.appleSounds) + "Suoni di sistema Apple") { use(AppSettings.appleSounds) }
            }
            Section(header: Text("Scaricati")) {
                ForEach(downloaded, id: \.self) { u in
                    Button(check(u.path) + u.deletingPathExtension().lastPathComponent) { use(u.path) }
                }
                ForEach(SoundFontStore.offers.filter { !$0.parts.isEmpty || !$0.downloadURLs.isEmpty }) { o in
                    if store.installedURL(o) == nil {
                        Button("Scarica \(o.name) (\(o.size))…") { store.download(o) { u in use(u.path) } }
                    }
                }
            }
            if !settings.soundFontPath.isEmpty && settings.soundFontPath != AppSettings.appleSounds
                && !downloaded.contains(where: { $0.path == settings.soundFontPath }) {
                Section(header: Text("Personale")) {
                    Button("✓ " + settings.soundFontName) { }
                }
            }
            let plugins = GMSynth.installedInstruments()
            if !plugins.isEmpty {
                Section(header: Text("Strumenti professionali (Audio Unit)")) {
                    ForEach(plugins, id: \.self) { c in
                        let id = GMSynth.identifier(c.audioComponentDescription)
                        Button((settings.synthPluginID == id ? "✓ " : "") + "\(c.manufacturerName) — \(c.name)") {
                            settings.synthPluginID = id
                            settings.synthPluginName = "\(c.manufacturerName) \(c.name)"
                            player.usePlugin(id: id, name: settings.synthPluginName)
                        }
                    }
                }
            }
            Divider()
            Button("Scegli un file .sf2 dal Mac (es. Win Live)…") { chooseFile() }
        } label: {
            Label(store.downloading != nil ? "Scarico… \(Int(store.progress * 100))%" : "Suoni: \(settings.soundFontName)", systemImage: "pianokeys.inverse")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func check(_ path: String) -> String {
        settings.synthPluginID.isEmpty && settings.soundFontPath == path ? "✓ " : ""
    }

    private func use(_ path: String) {
        settings.synthPluginID = ""
        settings.soundFontPath = path
        player.reloadSoundFont()
    }

    private func chooseFile() {
        let p = NSOpenPanel()
        p.allowedFileTypes = ["sf2", "dls"]
        if p.runModal() == .OK, let u = p.url { use(u.path) }
    }
}
