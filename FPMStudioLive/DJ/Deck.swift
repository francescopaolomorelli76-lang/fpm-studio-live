import Foundation
import AVFoundation

/// Le basi MIDI diventano audio (con il SoundFont scelto) per poterle mixare con gli mp3.
enum MIDIRenderCache {
    static func audioURL(for midiURL: URL, soundBank: String, progress: @escaping (Double) -> Void) throws -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: midiURL.path)
        let stamp = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(midiURL.path)|\(stamp)|\(soundBank)|\(AppSettings.shared.synthPluginID)".data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let out = AppPaths.renderCache.appendingPathComponent(String(key.suffix(100)) + ".wav")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        let midi = try MIDIFile(url: midiURL)
        var s = OfflineRenderer.Settings()
        s.soundBank = soundBank.isEmpty ? AppSettings.bundledSoundFont : URL(fileURLWithPath: soundBank)
        var audio = try OfflineRenderer.render(midi, settings: s) { progress($0 * 0.85) }
        Mastering.master(&audio.left, &audio.right, sr: audio.sampleRate, mode: .natural, applyEQ: false)
        try AudioExporter.write(audio, to: out, format: .wav) { progress(0.85 + $0 * 0.15) }
        return out
    }
}

/// Un deck DJ: lettore con pitch/tempo, EQ a tre bande, volume, cue e analisi BPM.
final class Deck: ObservableObject, Identifiable {
    let id: String
    let nodes: AudioHub.DeckNodes
    @Published private(set) var title = "Trascina un brano qui"
    @Published private(set) var url: URL?
    @Published private(set) var loading = false
    @Published private(set) var loadProgress = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var bpm: Double?
    @Published private(set) var waveform: [Float] = []
    @Published private(set) var leadIn = 0.0
    @Published private(set) var lastSound = 0.0
    /// Battiti (secondi nel file) e indice del primo "uno" di battuta, dall'analisi.
    private(set) var beats: [Double] = []
    private(set) var downbeatOffset = 0
    @Published var cuePoint = 0.0
    @Published var error: String?

    @Published var volume: Double = 1 { didSet { applyVolume() } }
    @Published var pitchPercent: Double = 0 { didSet { nodes.timePitch.rate = Float(1 + pitchPercent / 100) } }
    @Published var keyLock = true { didSet { applyKey() } }
    @Published var eqLow: Double = 0 { didSet { nodes.eq.bands[0].gain = Float(eqLow) } }
    @Published var eqMid: Double = 0 { didSet { nodes.eq.bands[1].gain = Float(eqMid) } }
    @Published var eqHigh: Double = 0 { didSet { nodes.eq.bands[2].gain = Float(eqHigh) } }
    /// Guadagno imposto dal crossfader (0...1).
    var crossfadeGain: Double = 1 { didSet { applyVolume() } }

    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var token = 0
    var onEnd: (() -> Void)?

    init(id: String, nodes: AudioHub.DeckNodes) {
        self.id = id
        self.nodes = nodes
        applyVolume()
        NotificationCenter.default.addObserver(forName: AudioHub.restartedNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self, self.isPlaying else { return }
            self.updatePosition()
            let p = self.position
            self.isPlaying = false
            self.seek(to: p)
            self.play()
        }
    }

    private func applyVolume() { nodes.volume.outputVolume = Float(volume * crossfadeGain) }
    private func applyKey() {
        // Senza key lock il tono segue la velocità come un giradischi.
        nodes.timePitch.pitch = keyLock ? 0 : Float(1200 * log2(1 + pitchPercent / 100))
    }

    var effectiveBPM: Double? { bpm.map { $0 * (1 + pitchPercent / 100) } }
    var remaining: Double { max(0, (lastSound > 0 ? lastSound : duration) - position) / (1 + pitchPercent / 100) }

    func load(_ url: URL, soundBank: String, completion: (() -> Void)? = nil) {
        stop()
        loading = true
        loadProgress = 0
        title = url.deletingPathExtension().lastPathComponent
        self.url = url
        error = nil
        let isMIDI = ["mid", "midi", "kar"].contains(url.pathExtension.lowercased())
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var audioURL = url
                if isMIDI {
                    audioURL = try MIDIRenderCache.audioURL(for: url, soundBank: soundBank) { p in
                        DispatchQueue.main.async { self.loadProgress = p * 0.7 }
                    }
                } else {
                    // ZIP/MP3+G, e MP3 che Core Audio non apre direttamente (convertiti una volta in cache).
                    audioURL = try AudioDecode.playableURL(MediaResolver.resolve(url).audio)
                }
                let f = try AVAudioFile(forReading: AudioDecode.engineReadyURL(audioURL, format: AudioHub.shared.engineFormat))
                let an = try? AudioAnalyzer.analyze(url: audioURL) { p in
                    DispatchQueue.main.async { self.loadProgress = (isMIDI ? 0.7 : 0) + p * (isMIDI ? 0.3 : 1) }
                }
                DispatchQueue.main.async {
                    self.file = f
                    self.beats = an?.beats ?? []
                    self.downbeatOffset = an?.downbeatOffset ?? 0
                    self.duration = Double(f.length) / f.processingFormat.sampleRate
                    self.bpm = an?.bpm
                    self.waveform = an?.waveform ?? []
                    self.leadIn = an?.leadIn ?? 0
                    self.lastSound = an?.lastSound ?? self.duration
                    self.cuePoint = max(0, self.leadIn - 0.05)
                    self.startFrame = AVAudioFramePosition(self.cuePoint * f.processingFormat.sampleRate)
                    self.position = self.cuePoint
                    self.loading = false
                    completion?()
                }
            } catch {
                DispatchQueue.main.async {
                    self.loading = false
                    self.error = "Non riesco ad aprire \(url.lastPathComponent): \(error.localizedDescription)"
                    self.title = "Errore: " + (url.lastPathComponent)
                    self.url = nil
                }
            }
        }
    }

    /// Ricollega lettore → tono/tempo → EQ → volume con il formato del file (mono/stereo, qualunque frequenza).
    private func connect(format: AVAudioFormat) {
        let e = AudioHub.shared.engine
        nodes.player.stop()
        e.disconnectNodeOutput(nodes.player)
        e.disconnectNodeOutput(nodes.timePitch)
        e.disconnectNodeOutput(nodes.eq)
        e.connect(nodes.player, to: nodes.timePitch, format: format)
        e.connect(nodes.timePitch, to: nodes.eq, format: format)
        e.connect(nodes.eq, to: nodes.volume, fromBus: 0, toBus: 0, format: format)
    }

    func updatePosition() {
        guard let f = file else { return }
        let sr = f.processingFormat.sampleRate
        if isPlaying, let nt = nodes.player.lastRenderTime, let pt = nodes.player.playerTime(forNodeTime: nt) {
            position = min(duration, max(Double(startFrame) / sr, Double(startFrame) / sr + Double(pt.sampleTime) / pt.sampleRate))
        }
    }

    var rate: Double { 1 + pitchPercent / 100 }

    /// Prossimo "uno" di battuta (secondi nel file) dopo `t`; se l'analisi non ha battute, nil.
    func nextDownbeat(after t: Double) -> Double? {
        guard beats.count > 8 else { return nil }
        if let i = beats.indices.first(where: { beats[$0] > t && ($0 - downbeatOffset) % 4 == 0 }) { return beats[i] }
        return beats.first { $0 > t }
    }

    /// Primo "uno" di battuta dopo l'attacco del brano (punto di ingresso nel mix).
    var firstDownbeat: Double {
        guard beats.count > 8 else { return max(0, leadIn - 0.02) }
        let i = beats.indices.first { beats[$0] >= leadIn - 0.08 && ($0 - downbeatOffset) % 4 == 0 } ?? 0
        return beats[i]
    }

    /// Partenza a un istante preciso (per far coincidere le battute dei due deck).
    func play(after delay: Double) {
        guard delay > 0.01 else { play(); return }
        let host = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay)
        play(at: AVAudioTime(hostTime: host))
    }

    func play() { play(at: nil) }

    func play(at when: AVAudioTime?) {
        guard let f = file, !isPlaying else { return }
        AudioHub.shared.start()
        let remaining = AVAudioFrameCount(max(0, f.length - startFrame))
        guard remaining > 0 else { return }
        token += 1
        let tk = token
        nodes.player.scheduleSegment(f, startingFrame: startFrame, frameCount: remaining, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.token == tk, self.isPlaying else { return }
                self.isPlaying = false
                self.onEnd?()
            }
        }
        nodes.player.play(at: when)
        isPlaying = true
    }

    func pause() {
        guard isPlaying, let f = file else { return }
        updatePosition()
        token += 1
        isPlaying = false
        nodes.player.stop()
        startFrame = AVAudioFramePosition(position * f.processingFormat.sampleRate)
    }

    func stop() {
        token += 1
        isPlaying = false
        nodes.player.stop()
        startFrame = 0
        position = 0
    }

    /// Svuota il deck (dopo un mix automatico, così si carica il brano successivo).
    func unload() {
        stop()
        file = nil
        url = nil
        title = "Trascina un brano qui"
        waveform = []
        duration = 0
        bpm = nil
        lastSound = 0
        pitchPercent = 0
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        guard let f = file else { return }
        let was = isPlaying
        if was { token += 1; isPlaying = false; nodes.player.stop() }
        position = max(0, min(seconds, duration))
        startFrame = AVAudioFramePosition(position * f.processingFormat.sampleRate)
        if was { play() }
    }

    /// CUE classico: in pausa memorizza il punto, in riproduzione torna al punto e si ferma.
    func cue() {
        if isPlaying { pause(); seek(to: cuePoint) } else { updatePosition(); cuePoint = position }
    }

    /// Allinea il BPM a quello dell'altro deck.
    func sync(to other: Deck) {
        guard let mine = bpm, let target = other.effectiveBPM, mine > 0 else { return }
        var ratio = target / mine
        // Considera metà/doppio tempo.
        if ratio > 1.5 { ratio /= 2 } else if ratio < 0.67 { ratio *= 2 }
        pitchPercent = max(-16, min(16, (ratio - 1) * 100))
    }
}
