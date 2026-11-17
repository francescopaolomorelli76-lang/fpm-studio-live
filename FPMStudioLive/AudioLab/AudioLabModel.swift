import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Audio Lab: da un link o da un file a MP3, WAV e tutti gli altri formati,
/// con taglio, divisione in parti, separazione voce/base, trasposizione e mastering ascoltabili prima di esportare.
final class AudioLabModel: ObservableObject {
    /// Che cosa esportare del brano.
    enum Part: String, CaseIterable, Identifiable {
        case full, instrumentalQuick, aiInstrumental, aiVocals, aiAll
        var id: String { rawValue }
        var label: String {
            switch self {
            case .full: return "Brano intero"
            case .instrumentalQuick: return "Base senza voce (rapida, sul Mac)"
            case .aiInstrumental: return "Base senza voce (AI)"
            case .aiVocals: return "Solo voce (AI)"
            case .aiAll: return "Tutte le tracce separate (AI)"
            }
        }
        var needsAI: Bool { self == .aiInstrumental || self == .aiVocals || self == .aiAll }
    }

    enum MasterMode: String, CaseIterable, Identifiable {
        case off, natural, pro
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Nessuno (originale)"
            case .natural: return "Naturale (-16 LUFS)"
            case .pro: return "Professionale (-14 LUFS)"
            }
        }
    }

    // MARK: Sorgente
    @Published var link = ""
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published var error: String?
    @Published private(set) var sourceURL: URL?
    @Published private(set) var title = ""
    @Published private(set) var duration = 0.0
    @Published private(set) var ytdlpInstalled = LinkDownloader.executable != nil
    private var original: RenderedAudio?
    private var stems: [String: RenderedAudio] = [:]

    // MARK: Modifiche
    @Published var trimStart = 0.0 { didSet { changed() } }
    @Published var trimEnd = 0.0 { didSet { changed() } }
    /// Punti in cui dividere il brano in più file (secondi del brano originale).
    @Published private(set) var cuts: [Double] = []
    @Published var part: Part = .full { didSet { changed() } }
    @Published var semitones = 0 { didSet { changed() } }
    @Published var tempo = 1.0 { didSet { changed() } }
    @Published var master: MasterMode = .natural { didSet { changed() } }
    @Published var eq = false { didSet { changed() } }
    @Published var fadeOut = true { didSet { changed() } }

    // MARK: Ascolto ed esportazione
    let preview = PreviewPlayer()
    @Published private(set) var previewReady = false
    @Published private(set) var listeningOriginal = false
    @Published var formats: Set<AudioLabFormat> = [.mp3_320, .wav24]
    @Published var outputFolder: URL = {
        let u = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("FPM Studio Live", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    @Published private(set) var exported: [URL] = []
    private var previewGeneration = 0
    private var previewWork: DispatchWorkItem?

    var hasSource: Bool { original != nil }
    var stemNames: [String] { stems.keys.sorted() }

    // MARK: Caricamento

    func installYtdlp() {
        run("Installo yt-dlp…") {
            try await LinkDownloader.install()
            await MainActor.run { self.ytdlpInstalled = LinkDownloader.executable != nil; self.status = "yt-dlp installato" }
        }
    }

    func updateYtdlp() {
        run("Aggiorno yt-dlp…") {
            let msg = try await LinkDownloader.update()
            await MainActor.run { self.status = msg }
        }
    }

    func downloadLink() {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard l.hasPrefix("http") else { error = "Incolla un link completo (https://…)"; return }
        run("Scarico l'audio dal link…") {
            let url = try await LinkDownloader.download(l) { p, msg in
                DispatchQueue.main.async { self.progress = p * 0.8; self.status = msg }
            }
            try await self.loadAsync(url)
        }
    }

    func openFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .audiovisualContent]
        p.message = "Scegli un brano o un video"
        guard p.runModal() == .OK, let u = p.url else { return }
        open(u)
    }

    func open(_ u: URL) {
        run("Apro \(u.lastPathComponent)…") { try await self.loadAsync(u) }
    }

    private func loadAsync(_ u: URL) async throws {
        await MainActor.run { self.status = "Leggo l'audio…" }
        let a = try AudioLabDSP.decode(u)
        await MainActor.run {
            self.original = a
            self.stems = [:]
            self.sourceURL = u
            self.title = u.deletingPathExtension().lastPathComponent.replacingOccurrences(of: #" \[[A-Za-z0-9_-]{6,}\]$"#, with: "", options: .regularExpression)
            self.duration = a.duration
            self.cuts = []
            self.exported = []
            self.part = .full
            self.trimStart = 0
            self.trimEnd = a.duration
            self.status = "Pronto: \(formatTime(a.duration))"
            self.changed()
        }
    }

    // MARK: Divisione in parti

    func addCut(at t: Double) {
        let lo = trimStart + 1, hi = (trimEnd > 0 ? trimEnd : duration) - 1
        guard t > lo, t < hi, !cuts.contains(where: { abs($0 - t) < 1 }) else { return }
        cuts = (cuts + [t]).sorted()
    }

    func addCutAtPlayhead() {
        // L'anteprima parte dall'inizio del taglio e può avere un altro tempo.
        addCut(at: trimStart + preview.position * tempo)
    }

    func splitEvenly(_ n: Int) {
        let end = trimEnd > 0 ? trimEnd : duration
        let len = (end - trimStart) / Double(n)
        cuts = (1..<n).map { trimStart + Double($0) * len }
    }

    func removeCut(_ t: Double) { cuts.removeAll { $0 == t } }
    func clearCuts() { cuts = [] }

    // MARK: Elaborazione

    /// Tracce da esportare (nome → audio) per la scelta attuale, prima di taglio e mastering.
    private func sources() async throws -> [(String, RenderedAudio)] {
        guard let a = original else { return [] }
        switch part {
        case .full: return [("", a)]
        case .instrumentalQuick: return [("Base", AudioLabDSP.quickInstrumental(a))]
        case .aiInstrumental, .aiVocals, .aiAll:
            try await ensureStems(a)
            let s = await MainActor.run { self.stems }
            let vocals = s["vocals"]
            let others = s.filter { $0.key != "vocals" }.map { $0.value }
            switch part {
            case .aiVocals: return vocals.map { [("Voce", $0)] } ?? []
            case .aiInstrumental: return AudioLabDSP.mix(others).map { [("Base", $0)] } ?? []
            default:
                var out: [(String, RenderedAudio)] = []
                if let v = vocals { out.append(("Voce", v)) }
                if let b = AudioLabDSP.mix(others) { out.append(("Base", b)) }
                let names = ["drums": "Batteria", "bass": "Basso", "other": "Altri strumenti", "guitar": "Chitarra", "piano": "Pianoforte"]
                for (k, v) in s.sorted(by: { $0.key < $1.key }) where k != "vocals" { out.append((names[k] ?? k.capitalized, v)) }
                return out
            }
        }
    }

    private func ensureStems(_ a: RenderedAudio) async throws {
        if await MainActor.run(body: { !self.stems.isEmpty }) { return }
        let token = Keychain.get(MusicProvider.replicate.rawValue)
        guard !token.isEmpty else {
            throw MusicProviderError.noAudio("per la separazione AI serve la chiave Replicate: inseriscila in AI Studio (scegli Replicate e premi \"Ottieni la chiave\"). Senza chiave usa \"Base senza voce (rapida)\".")
        }
        let s = try await StemSeparator.separate(a, token: token) { msg in DispatchQueue.main.async { self.status = msg } }
        await MainActor.run { self.stems = s }
    }

    /// Taglio, tono/tempo, mastering e dissolvenza su una traccia.
    private func process(_ a: RenderedAudio, from: Double, to: Double, fadeIn: Bool, fadeOutEnd: Bool) throws -> RenderedAudio {
        var x = a.slice(from: from, to: to, fadeIn: fadeIn ? 0.02 : 0.005, fadeOut: fadeOutEnd ? 2.5 : 0.02)
        x = try AudioLabDSP.pitchAndTempo(x, semitones: Double(semitones), tempo: tempo)
        if master != .off {
            Mastering.master(&x.left, &x.right, sr: x.sampleRate, mode: master == .pro ? .pro : .natural, applyEQ: eq)
        }
        return x
    }

    private var end: Double { trimEnd > 0 ? min(trimEnd, duration) : duration }

    // MARK: Ascolto

    /// Dopo ogni modifica l'anteprima si rifà da sola (con mezzo secondo di attesa).
    private func changed() {
        previewReady = false
        previewWork?.cancel()
        guard original != nil else { return }
        // La separazione AI costa crediti: parte solo quando premi "Ascolta".
        if part.needsAI && stems.isEmpty { return }
        let w = DispatchWorkItem { [weak self] in self?.makePreview(autoplay: false) }
        previewWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    func makePreview(autoplay: Bool = true) {
        guard original != nil else { return }
        previewGeneration += 1
        let gen = previewGeneration
        let wasPos = preview.position
        listeningOriginal = false
        run("Preparo l'ascolto con le modifiche…", blocking: part.needsAI && stems.isEmpty) {
            let srcs = try await self.sources()
            guard let first = srcs.first else { throw RenderError.empty }
            let (from, to, fade) = await MainActor.run { (self.trimStart, self.end, self.fadeOut) }
            let x = try self.process(first.1, from: from, to: to, fadeIn: from > 0.1, fadeOutEnd: fade && to < self.duration - 0.5)
            let dest = AppPaths.renderCache.appendingPathComponent("audiolab-anteprima-\(gen).m4a")
            try AudioExporter.write(x, to: dest, format: .m4a)
            await MainActor.run {
                guard gen == self.previewGeneration else { return }
                self.preview.load(dest, title: self.title + (first.0.isEmpty ? "" : " – \(first.0)") + " (con modifiche)", autoplay: autoplay)
                if !autoplay, wasPos > 0 { self.preview.seek(min(wasPos, self.preview.duration)) }
                self.previewReady = true
                self.status = "Anteprima pronta: ascolta prima di esportare"
            }
        }
    }

    /// Confronto: ascolta il brano originale, senza modifiche.
    func listenOriginal() {
        guard let u = sourceURL else { return }
        preview.load(u, title: title + " (originale)", autoplay: true)
        listeningOriginal = true
        previewReady = false
    }

    // MARK: Esportazione

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Scegli"
        if p.runModal() == .OK, let u = p.url { outputFolder = u }
    }

    func export() {
        guard original != nil, !formats.isEmpty else { error = "Scegli almeno un formato"; return }
        let fmts = AudioLabFormat.allCases.filter { formats.contains($0) }
        run("Esporto…", blocking: true) {
            let srcs = try await self.sources()
            let (from, to, fade, cuts, folder, base) = await MainActor.run {
                (self.trimStart, self.end, self.fadeOut, self.cuts.filter { $0 > self.trimStart && $0 < self.end }, self.outputFolder, self.safeTitle)
            }
            let bounds = [from] + cuts + [to]
            let parts = cuts.isEmpty ? 1 : bounds.count - 1
            var written: [URL] = []
            var failures: [String] = []
            let jobs = srcs.count * parts * fmts.count
            var done = 0
            for (stemName, audio) in srcs {
                for i in 0..<parts {
                    let a = bounds[i], b = bounds[i + 1]
                    let x = try self.process(audio, from: a, to: b, fadeIn: a > 0.1, fadeOutEnd: fade && i == parts - 1 && b < self.duration - 0.5)
                    var name = base
                    if !stemName.isEmpty { name += " - " + stemName }
                    if parts > 1 { name += String(format: " - parte %02d", i + 1) }
                    if self.semitones != 0 { name += self.semitones > 0 ? " (+\(self.semitones))" : " (\(self.semitones))" }
                    for f in fmts {
                        let url = folder.appendingPathComponent(name + f.suffix)
                        await MainActor.run { self.status = "Scrivo \(url.lastPathComponent)…" }
                        do { try AudioLabDSP.write(x, to: url, format: f); written.append(url) }
                        catch { failures.append(error.localizedDescription) }
                        done += 1
                        let p = Double(done) / Double(max(1, jobs))
                        await MainActor.run { self.progress = p }
                    }
                }
            }
            await MainActor.run {
                self.exported = written
                self.status = "Esportati \(written.count) file in \(folder.lastPathComponent)"
                if !failures.isEmpty { self.error = "Alcuni formati non sono riusciti: " + Set(failures).joined(separator: "; ") }
            }
        }
    }

    func revealExported() {
        if exported.isEmpty { NSWorkspace.shared.open(outputFolder) } else { NSWorkspace.shared.activateFileViewerSelecting(exported) }
    }

    private var safeTitle: String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let t = title.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Brano" : String(t.prefix(80))
    }

    // MARK: Utilità

    /// Esegue un lavoro in background con stato, avanzamento ed errori mostrati nella sezione.
    private func run(_ message: String, blocking: Bool = true, _ work: @escaping () async throws -> Void) {
        if blocking { busy = true }
        progress = 0
        status = message
        error = nil
        Task.detached(priority: .userInitiated) {
            do { try await work() }
            catch { await MainActor.run { self.error = error.localizedDescription; self.status = "" } }
            if blocking { await MainActor.run { self.busy = false } }
        }
    }
}
