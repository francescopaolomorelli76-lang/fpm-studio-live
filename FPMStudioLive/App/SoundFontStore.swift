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
}

final class SoundFontStore: ObservableObject {
    static let offers: [SoundFontOffer] = [
        SoundFontOffer(id: "sc-va", name: "Roland Sound Canvas VA (consigliato)",
                       detail: "Il modulo GS originale Roland su cui sono programmate quasi tutte le basi MIDI karaoke. Plugin Audio Unit: dopo l'installazione sceglilo in \"Strumento professionale\".",
                       size: "—", license: "Commerciale (Roland Cloud)", downloadURLs: [],
                       page: URL(string: "https://www.roland.com/global/products/rc_sound_canvas_va/")!, fileName: ""),
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
                    } else if o.downloadURLs.isEmpty {
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
