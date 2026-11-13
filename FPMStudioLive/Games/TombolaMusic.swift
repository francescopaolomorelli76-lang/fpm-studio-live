import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// Musica di sottofondo della tombola: una scaletta di brani (MP3, M4A, WAV…) che suonano uno dopo l'altro
/// per tutta la serata. Quando la voce annuncia un numero il volume si abbassa da solo e poi risale.
final class TombolaMusic: NSObject, ObservableObject, AVAudioPlayerDelegate {
    private let d = UserDefaults.standard
    @Published private(set) var tracks: [URL] = [] { didSet { d.set(tracks.map { $0.path }, forKey: "tmb.music") } }
    @Published var volume: Double { didSet { d.set(volume, forKey: "tmb.musicVol"); applyVolume(fade: 0.2) } }
    /// Volume durante la voce, in proporzione (0.2 = 20%).
    @Published var duckLevel: Double { didSet { d.set(duckLevel, forKey: "tmb.duck") } }
    @Published var shuffle: Bool { didSet { d.set(shuffle, forKey: "tmb.shuffle") } }
    /// La musica parte da sola con la partita.
    @Published var autoStart: Bool { didSet { d.set(autoStart, forKey: "tmb.musicAuto") } }
    @Published private(set) var isPlaying = false
    @Published private(set) var currentIndex: Int?
    @Published private(set) var error: String?

    private var player: AVAudioPlayer?
    private var ducked = false
    private var failures = 0

    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac"]

    override init() {
        volume = d.object(forKey: "tmb.musicVol") as? Double ?? 0.6
        duckLevel = d.object(forKey: "tmb.duck") as? Double ?? 0.25
        shuffle = d.object(forKey: "tmb.shuffle") as? Bool ?? true
        autoStart = d.object(forKey: "tmb.musicAuto") as? Bool ?? true
        super.init()
        tracks = (d.stringArray(forKey: "tmb.music") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        // Se parte il karaoke o Atomix, il sottofondo della tombola si ferma.
        ExclusivePlayback.observe({ "tombola-music" }) { [weak self] in
            guard let self = self, self.isPlaying else { return }
            self.stop()
        }
    }

    var currentTitle: String {
        guard let i = currentIndex, i < tracks.count else { return "" }
        return tracks[i].deletingPathExtension().lastPathComponent
    }

    // MARK: Scaletta

    /// Aggiunge brani o intere cartelle (per esempio "Canzoni di Natale").
    func addFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.allowedContentTypes = [.audio, .folder]
        p.message = "Scegli i brani o le cartelle di musica per il sottofondo"
        guard p.runModal() == .OK else { return }
        add(p.urls)
    }

    func add(_ urls: [URL]) {
        var found: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if TombolaMusic.audioExtensions.contains(f.pathExtension.lowercased()) { found.append(f) }
                }
            } else if TombolaMusic.audioExtensions.contains(u.pathExtension.lowercased()) {
                found.append(u)
            }
        }
        let existing = Set(tracks.map { $0.path })
        tracks += found.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .filter { !existing.contains($0.path) }
    }

    func remove(at i: Int) {
        guard i < tracks.count else { return }
        if currentIndex == i { stop() }
        tracks.remove(at: i)
        if let c = currentIndex, c > i { currentIndex = c - 1 }
    }

    func clear() { stop(); tracks = [] }

    // MARK: Riproduzione

    func toggle() { isPlaying ? stop() : play() }

    func play() {
        guard !tracks.isEmpty else { error = "Aggiungi prima qualche brano"; return }
        error = nil
        failures = 0
        ExclusivePlayback.announce("tombola-music")
        if let p = player, !p.isPlaying, currentIndex != nil {
            p.volume = 0
            p.play()
            isPlaying = true
            applyVolume(fade: 2)
            return
        }
        playIndex(shuffle ? Int.random(in: 0..<tracks.count) : (currentIndex.map { ($0 + 1) % tracks.count } ?? 0))
    }

    func stop() {
        player?.setVolume(0, fadeDuration: 1)
        let p = player
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { if p?.volume == 0 { p?.pause() } }
        isPlaying = false
    }

    func next() {
        guard !tracks.isEmpty else { return }
        var n = ((currentIndex ?? -1) + 1) % tracks.count
        if shuffle && tracks.count > 1 {
            repeat { n = Int.random(in: 0..<tracks.count) } while n == currentIndex
        }
        playIndex(n)
    }

    func playIndex(_ i: Int) {
        guard i >= 0, i < tracks.count else { return }
        player?.stop()
        guard let p = try? AVAudioPlayer(contentsOf: tracks[i]) else {
            // File protetto o rovinato (per esempio brani scaricati da servizi in abbonamento): si salta.
            failures += 1
            error = "Non riesco a suonare \"\(tracks[i].lastPathComponent)\": lo salto"
            currentIndex = i
            if failures < tracks.count { next() } else { isPlaying = false }
            return
        }
        failures = 0
        p.delegate = self
        p.volume = 0
        p.prepareToPlay()
        p.play()
        player = p
        currentIndex = i
        isPlaying = true
        applyVolume(fade: 2)
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { if self.isPlaying && p === self.player { self.next() } }
    }

    /// Abbassa la musica mentre parla la voce.
    func duck(_ on: Bool) {
        guard ducked != on else { return }
        ducked = on
        applyVolume(fade: on ? 0.4 : 1.5)
    }

    private func applyVolume(fade: TimeInterval) {
        guard let p = player, isPlaying else { return }
        let target = Float(volume * (ducked ? duckLevel : 1))
        p.setVolume(target, fadeDuration: fade)
    }
}
