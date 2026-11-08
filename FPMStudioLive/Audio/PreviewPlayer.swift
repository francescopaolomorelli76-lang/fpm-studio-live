import Foundation
import AVFoundation
import SwiftUI

/// Lettore indipendente (AVAudioPlayer): non usa il motore del karaoke né i deck DJ, quindi può suonare
/// accanto a loro senza fermarli. Usato da Piano Studio, AI Studio e Sottofondo.
/// I MIDI vengono prima trasformati in audio con il SoundFont indicato (una volta, poi restano in cache).
final class PreviewPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var preparing = false
    @Published private(set) var prepareProgress = 0.0
    @Published var volume: Double = 1 { didSet { player?.volume = Float(volume) } }
    @Published var error: String?
    /// Fattore per convertire il tempo del file nel tempo del brano originale (MIDI renderizzati con un altro tempo).
    var timeScale = 1.0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    var songPosition: Double { position * timeScale }

    /// Apre un file audio (MP3/M4A/WAV…, anche ZIP MP3+G).
    func load(_ u: URL, title: String? = nil, autoplay: Bool = false) {
        stop()
        error = nil
        do {
            let audio = try AudioDecode.playableURL(MediaResolver.resolve(u).audio)
            let p = try AVAudioPlayer(contentsOf: audio)
            p.delegate = self
            p.enableRate = true
            p.volume = Float(volume)
            p.prepareToPlay()
            player = p
            url = u
            self.title = title ?? u.deletingPathExtension().lastPathComponent
            duration = p.duration
            position = 0
            timeScale = 1
            if autoplay { play() }
        } catch {
            self.error = "Non riesco ad aprire \(u.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// Rende un MIDI in audio (in background, con cache) e lo apre.
    func loadMIDI(_ midi: MIDIFile, key: String, title: String, settings: OfflineRenderer.Settings, autoplay: Bool = true, onReady: (() -> Void)? = nil) {
        stop()
        let dest = AppPaths.renderCache.appendingPathComponent("anteprima-" + StableHash.hex(key) + ".m4a")
        let scale = settings.tempo
        if FileManager.default.fileExists(atPath: dest.path) {
            load(dest, title: title, autoplay: autoplay); timeScale = scale; onReady?(); return
        }
        preparing = true
        prepareProgress = 0
        self.title = title
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var a = try OfflineRenderer.render(midi, settings: settings) { p in DispatchQueue.main.async { self.prepareProgress = p * 0.9 } }
                Mastering.master(&a.left, &a.right, sr: a.sampleRate, mode: .natural, applyEQ: false)
                try AudioExporter.write(a, to: dest, format: .m4a)
                DispatchQueue.main.async {
                    self.preparing = false
                    self.load(dest, title: title, autoplay: autoplay)
                    self.timeScale = scale
                    onReady?()
                }
            } catch {
                DispatchQueue.main.async { self.preparing = false; self.error = error.localizedDescription }
            }
        }
    }

    private lazy var sourceID = "anteprima-\(ObjectIdentifier(self).hashValue)"
    private var exclusiveObserver: NSObjectProtocol?

    func play() {
        guard let p = player else { return }
        if exclusiveObserver == nil {
            exclusiveObserver = ExclusivePlayback.observe({ [weak self] in self?.sourceID ?? "" }) { [weak self] in
                if self?.isPlaying == true { self?.pause() }
            }
        }
        ExclusivePlayback.announce(sourceID)
        p.play()
        isPlaying = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self, let p = self.player else { return }
            self.position = p.currentTime
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func pause() { player?.pause(); isPlaying = false; timer?.invalidate() }
    func toggle() { isPlaying ? pause() : play() }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        position = 0
        timer?.invalidate()
    }

    /// Salta a un istante del file (secondi del file).
    func seek(_ t: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(t, p.duration))
        position = p.currentTime
    }

    /// Salta a un istante del brano originale (tiene conto del tempo modificato).
    func seekSong(_ t: Double) { seek(t / max(0.01, timeScale)) }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.isPlaying = false; self.timer?.invalidate(); self.position = self.duration }
    }
}

/// Lettore piccolo: titolo, play/pausa, stop, barra di avanzamento. Accetta file trascinati.
struct MiniPlayerView: View {
    @ObservedObject var player: PreviewPlayer
    var accent: Color = Theme.cyan
    var acceptsDrop = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button(action: { player.toggle() }) { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 22) }
                    .buttonStyle(NeonButtonStyle()).disabled(player.url == nil)
                Button(action: { player.stop() }) { Image(systemName: "stop.fill") }
                    .buttonStyle(NeonButtonStyle(prominent: false)).disabled(player.url == nil)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.preparing ? "Preparo l'audio… \(Int(player.prepareProgress * 100))%" : (player.title.isEmpty ? "Trascina qui un brano" : player.title))
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("\(formatTime(player.position)) / \(formatTime(player.duration))").font(.system(size: 10)).monospacedDigit().foregroundColor(Theme.soft)
                }
                Spacer()
                Image(systemName: "speaker.wave.2").foregroundColor(Theme.soft)
                Slider(value: $player.volume, in: 0...1).frame(width: 70).controlSize(.mini)
            }
            Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...max(1, player.duration)).controlSize(.small).accentColor(accent)
            if let e = player.error { Text(e).font(.caption).foregroundColor(Theme.warn).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
        .onDrop(of: acceptsDrop ? [.fileURL] : [], isTargeted: nil) { providers in
            DropHelper.urls(from: providers) { urls in if let u = urls.first { player.load(u, autoplay: true) } }
            return acceptsDrop
        }
    }
}

/// Lettura affidabile dei file trascinati (dal Finder e dall'archivio dell'app).
enum DropHelper {
    static func urls(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        var found: [URL] = []
        let group = DispatchGroup()
        let lock = NSLock()
        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier("public.file-url") {
                p.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    var u: URL?
                    if let d = item as? Data { u = URL(dataRepresentation: d, relativeTo: nil) }
                    else if let x = item as? URL { u = x }
                    else if let s = item as? String { u = URL(string: s) }
                    if let u = u { lock.lock(); found.append(u.standardizedFileURL); lock.unlock() }
                    group.leave()
                }
            } else {
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u = u { lock.lock(); found.append(u); lock.unlock() }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(found) }
    }
}
