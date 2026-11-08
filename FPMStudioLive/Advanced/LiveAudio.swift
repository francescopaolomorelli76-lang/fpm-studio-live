import Foundation
import AVFoundation
import Combine
import CoreAudio
import AudioToolbox

/// Collega dinamicamente un nodo al motore principale (si può fare anche mentre suona).
private func attachToMain(_ nodes: [AVAudioNode], chainTo mixer: AVAudioMixerNode) {
    let e = AudioHub.shared.engine
    for n in nodes where n.engine == nil { e.attach(n) }
    if mixer.engine == nil {
        e.attach(mixer)
        e.connect(mixer, to: e.mainMixerNode, format: nil)
    }
}

/// Legge un file audio intero in memoria (per campioni brevi).
private func loadBuffer(_ url: URL) throws -> AVAudioPCMBuffer {
    let f = try AVAudioFile(forReading: url)
    guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else {
        throw RenderError.engine("memoria")
    }
    try f.read(into: b)
    return b
}

// MARK: - Campionatore (G05): 100 slot, loop, gruppi di stop, volume, precaricamento

struct SampleSlot: Codable, Identifiable, Hashable {
    var id: Int                     // 1…100
    var path: String?
    var name: String = ""
    var volume: Double = 1
    var loop = false
    var stopGroup = 0               // 0 = nessuno; uno slot ferma gli altri dello stesso gruppo
}

final class SamplerEngine: ObservableObject {
    static let slotCount = 100
    @Published var slots: [SampleSlot] { didSet { save() } }
    @Published private(set) var playing: Set<Int> = []
    @Published var page = 0                       // 5 pagine da 20
    @Published var masterVolume: Double = 1 { didSet { mixer.outputVolume = Float(masterVolume) } }

    private let mixer = AVAudioMixerNode()
    private var voices: [Int: AVAudioPlayerNode] = [:]
    private var buffers: [Int: AVAudioPCMBuffer] = [:]

    init() {
        if let d = UserDefaults.standard.data(forKey: "samplerSlots"), let s = try? JSONDecoder().decode([SampleSlot].self, from: d), s.count == SamplerEngine.slotCount {
            slots = s
        } else {
            slots = (1...SamplerEngine.slotCount).map { SampleSlot(id: $0) }
        }
    }

    private func save() { if let d = try? JSONEncoder().encode(slots) { UserDefaults.standard.set(d, forKey: "samplerSlots") } }

    func assign(_ url: URL, to id: Int) {
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[i].path = url.path
        slots[i].name = url.deletingPathExtension().lastPathComponent
        buffers[id] = try? loadBuffer(url)   // precaricamento
    }

    func clear(_ id: Int) {
        stop(id)
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[i] = SampleSlot(id: id)
        buffers[id] = nil
    }

    func trigger(_ id: Int) {
        guard let slot = slots.first(where: { $0.id == id }), let path = slot.path else { return }
        if playing.contains(id) { stop(id); return }
        if slot.stopGroup > 0 {
            for s in slots where s.stopGroup == slot.stopGroup && s.id != id { stop(s.id) }
        }
        if buffers[id] == nil { buffers[id] = try? loadBuffer(URL(fileURLWithPath: path)) }
        guard let buf = buffers[id] else { return }
        AudioHub.shared.start()
        let node: AVAudioPlayerNode
        if let v = voices[id], v.outputFormat(forBus: 0) == buf.format {
            node = v
        } else {
            if let old = voices[id] { old.stop(); AudioHub.shared.engine.detach(old) }
            node = AVAudioPlayerNode()
            attachToMain([node], chainTo: mixer)
            AudioHub.shared.engine.connect(node, to: mixer, format: buf.format)
            voices[id] = node
        }
        node.volume = Float(slot.volume)
        node.scheduleBuffer(buf, at: nil, options: slot.loop ? [.loops, .interrupts] : [.interrupts]) { [weak self] in
            DispatchQueue.main.async { if !(slot.loop) { self?.playing.remove(id) } }
        }
        node.play()
        playing.insert(id)
    }

    func stop(_ id: Int) {
        voices[id]?.stop()
        playing.remove(id)
    }

    func stopAll() { for id in playing { stop(id) } }
}

// MARK: - Musica di sottofondo (G04): parte da sola quando il palco è fermo

final class BackgroundMusic: ObservableObject {
    @Published var playlist: [URL] = [] { didSet { UserDefaults.standard.set(playlist.map { $0.path }, forKey: "bgPlaylist") } }
    @Published var enabled = false { didSet { enabled ? scheduleStartIfIdle() : fadeAndStop() } }
    @Published var volume: Double = 0.6 { didSet { if isPlaying { mixer.outputVolume = Float(volume) } } }
    @Published var delayAfterSong: Double = 5
    @Published var shuffle = true
    @Published private(set) var current: String = ""
    @Published private(set) var isPlaying = false

    private let node = AVAudioPlayerNode()
    private let mixer = AVAudioMixerNode()
    private var index = 0
    private var token = 0
    private var cancellable: AnyCancellable?
    private var pending: DispatchWorkItem?

    init() {
        playlist = (UserDefaults.standard.stringArray(forKey: "bgPlaylist") ?? []).map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Si sincronizza con il lettore karaoke: sfuma quando parte un brano, riparte quando si ferma.
    func bind(to player: KaraokePlayer) {
        cancellable = player.$isPlaying.removeDuplicates().sink { [weak self] playing in
            guard let self = self, self.enabled else { return }
            if playing { self.fadeAndStop() } else { self.scheduleStartIfIdle(player: player) }
        }
    }

    private func scheduleStartIfIdle(player: KaraokePlayer? = nil) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self, weak player] in
            guard let self = self, self.enabled, !(player?.isPlaying ?? false) else { return }
            self.playNext()
        }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delayAfterSong, execute: w)
    }

    /// Suona subito un brano (doppio clic dalla lista o dalla colonna cartella).
    func play(_ url: URL) {
        if !playlist.contains(url) { playlist.append(url) }
        if let i = playlist.firstIndex(of: url) { index = i - 1 }
        let wasShuffle = shuffle
        shuffle = false
        playNext()
        shuffle = wasShuffle
    }

    func playNext() {
        guard !playlist.isEmpty else { return }
        if shuffle { index = Int.random(in: 0..<playlist.count) } else { index = (index + 1) % playlist.count }
        let url = playlist[index]
        guard let f = try? AVAudioFile(forReading: url) else { return }
        AudioHub.shared.start()
        token += 1
        let tk = token
        node.stop()
        attachToMain([node], chainTo: mixer)
        AudioHub.shared.engine.connect(node, to: mixer, format: f.processingFormat)
        node.scheduleFile(f, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async { if let s = self, s.token == tk, s.enabled, s.isPlaying { s.playNext() } }
        }
        mixer.outputVolume = 0
        node.play()
        isPlaying = true
        current = url.deletingPathExtension().lastPathComponent
        ramp(to: Float(volume), seconds: 2, then: nil)
    }

    func fadeAndStop() {
        pending?.cancel()
        guard isPlaying else { return }
        ramp(to: 0, seconds: 1.5) { [weak self] in
            self?.token += 1
            self?.node.stop()
            self?.isPlaying = false
            self?.current = ""
        }
    }

    private func ramp(to target: Float, seconds: Double, then: (() -> Void)?) {
        let start = mixer.outputVolume
        let steps = max(1, Int(seconds * 20))
        var k = 0
        Timer.scheduledTimer(withTimeInterval: seconds / Double(steps), repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            k += 1
            self.mixer.outputVolume = start + (target - start) * Float(k) / Float(steps)
            if k >= steps { t.invalidate(); then?() }
        }
    }
}

// MARK: - Multitraccia (D01–D02, D06): fino a 16 stem sincronizzate, "non trasporre" per stem

struct StemTrack: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var name: String
    var gain: Double = 1
    var pan: Double = 0
    var mute = false
    var solo = false
    var noTranspose = false
    var offset: Double = 0          // secondi

    static func defaultNoTranspose(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["drum", "batter", "perc", "click", "metro", "kick", "snare", "cassa", "rullante"].contains { n.contains($0) }
    }
}

/// Progetto aperto `.stageproj` = cartella con manifest JSON + stem originali.
struct StageProject: Codable {
    var version = 1
    var title: String
    var stems: [StemTrack]
    var transpose = 0
    var tempo = 1.0
}

final class MultitrackPlayer: ObservableObject {
    static let maxStems = 16
    @Published var stems: [StemTrack] = [] { didSet { applyMix() } }
    @Published var title = ""
    @Published var transpose = 0 { didSet { applyPitch() } }
    @Published var tempo = 1.0 { didSet { applyPitch() } }
    @Published private(set) var isPlaying = false
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 0.0
    @Published var status = ""
    var projectURL: URL?

    private struct Chain { let player = AVAudioPlayerNode(); let pitch = AVAudioUnitTimePitch(); let file: AVAudioFile }
    private var chains: [UUID: Chain] = [:]
    private let bus = AVAudioMixerNode()
    private var startPos = 0.0
    private var timer: Timer?

    /// Carica tutti i file audio di una cartella (massimo 16).
    func loadFolder(_ dir: URL) {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["wav", "mp3", "m4a", "aif", "aiff", "flac", "caf"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if files.count > MultitrackPlayer.maxStems { status = "Trovate \(files.count) tracce: carico le prime 16" }
        let manifest = dir.appendingPathComponent("progetto.stageproj.json")
        if let d = try? Data(contentsOf: manifest), let p = try? JSONDecoder().decode(StageProject.self, from: d) {
            open(p, url: manifest); return
        }
        let st = files.prefix(MultitrackPlayer.maxStems).map { u -> StemTrack in
            let n = u.deletingPathExtension().lastPathComponent
            return StemTrack(path: u.path, name: n, noTranspose: StemTrack.defaultNoTranspose(n))
        }
        open(StageProject(title: dir.lastPathComponent, stems: Array(st)), url: manifest)
    }

    private func open(_ p: StageProject, url: URL) {
        stop()
        teardown()
        projectURL = url
        title = p.title
        var ok: [StemTrack] = []
        let e = AudioHub.shared.engine
        if bus.engine == nil { e.attach(bus); e.connect(bus, to: e.mainMixerNode, format: nil) }
        var maxDur = 0.0
        for s in p.stems {
            guard let f = try? AVAudioFile(forReading: URL(fileURLWithPath: s.path)) else { continue }
            let c = Chain(file: f)
            e.attach(c.player); e.attach(c.pitch)
            e.connect(c.player, to: c.pitch, format: f.processingFormat)
            e.connect(c.pitch, to: bus, format: f.processingFormat)
            chains[s.id] = c
            ok.append(s)
            maxDur = max(maxDur, Double(f.length) / f.processingFormat.sampleRate + s.offset)
        }
        duration = maxDur
        stems = ok
        transpose = p.transpose
        tempo = p.tempo
        status = "\(ok.count) tracce caricate"
    }

    private func teardown() {
        let e = AudioHub.shared.engine
        for c in chains.values { c.player.stop(); e.detach(c.player); e.detach(c.pitch) }
        chains = [:]
    }

    func save() {
        guard let u = projectURL else { return }
        let p = StageProject(title: title, stems: stems, transpose: transpose, tempo: tempo)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        do { try enc.encode(p).write(to: u); status = "Progetto salvato (\(u.lastPathComponent))" }
        catch { status = "Salvataggio non riuscito: \(error.localizedDescription)" }
    }

    private func applyMix() {
        let anySolo = stems.contains { $0.solo }
        for s in stems {
            guard let c = chains[s.id] else { continue }
            c.player.volume = (s.mute || (anySolo && !s.solo)) ? 0 : Float(s.gain)
            c.player.pan = Float(s.pan)
        }
        applyPitch()
    }

    private func applyPitch() {
        for s in stems {
            guard let c = chains[s.id] else { continue }
            c.pitch.pitch = s.noTranspose ? 0 : Float(transpose * 100)
            c.pitch.rate = Float(tempo)
        }
    }

    /// Avvio sincronizzato: tutti i lettori partono allo stesso istante audio.
    func play() {
        guard !isPlaying, !chains.isEmpty else { return }
        AudioHub.shared.start()
        let e = AudioHub.shared.engine
        let sr = e.outputNode.outputFormat(forBus: 0).sampleRate
        guard let now = e.outputNode.lastRenderTime, now.isSampleTimeValid else { status = "Audio non pronto"; return }
        let startAt = AVAudioTime(sampleTime: now.sampleTime + AVAudioFramePosition(0.2 * sr), atRate: sr)
        for s in stems {
            guard let c = chains[s.id] else { continue }
            let fsr = c.file.processingFormat.sampleRate
            let local = startPos - s.offset
            c.player.stop()
            if local >= 0 {
                let frame = AVAudioFramePosition(local * fsr)
                guard frame < c.file.length else { continue }
                c.player.scheduleSegment(c.file, startingFrame: frame, frameCount: AVAudioFrameCount(c.file.length - frame), at: nil)
                c.player.play(at: startAt)
            } else {
                c.player.scheduleSegment(c.file, startingFrame: 0, frameCount: AVAudioFrameCount(c.file.length), at: nil)
                let delay = AVAudioTime(sampleTime: startAt.sampleTime + AVAudioFramePosition(-local * sr / tempo), atRate: sr)
                c.player.play(at: delay)
            }
        }
        isPlaying = true
        timer?.invalidate()
        let t0 = Date()
        let base = startPos
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.position = min(self.duration, base + max(0, Date().timeIntervalSince(t0) - 0.2) * self.tempo)
            if self.position >= self.duration { self.stop() }
        }
    }

    func pause() {
        guard isPlaying else { return }
        startPos = position
        for c in chains.values { c.player.stop() }
        timer?.invalidate()
        isPlaying = false
    }

    func stop() {
        for c in chains.values { c.player.stop() }
        timer?.invalidate()
        isPlaying = false
        startPos = 0
        position = 0
    }

    func seek(_ t: Double) {
        let was = isPlaying
        pause()
        startPos = max(0, min(t, duration))
        position = startPos
        if was { play() }
    }
}

// MARK: - Medley Creator (G03): fino a 6 brani, trim, fade, incroci, gain, export

struct MedleyItem: Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var duration: Double
    var start: Double = 0
    var end: Double
    var fadeIn: Double = 0.5
    var fadeOut: Double = 3
    var crossfade: Double = 3        // sovrapposizione con il successivo
    var gainDb: Double = 0
}

final class MedleyCreator: ObservableObject {
    static let maxItems = 6
    @Published var items: [MedleyItem] = []
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published var status = ""
    @Published var normalize = true

    var totalDuration: Double {
        var t = 0.0
        for (i, it) in items.enumerated() {
            t += it.end - it.start
            if i < items.count - 1 { t -= min(it.crossfade, (it.end - it.start) / 2) }
        }
        return max(0, t)
    }

    func add(_ url: URL) {
        guard items.count < MedleyCreator.maxItems else { status = "Massimo \(MedleyCreator.maxItems) brani"; return }
        guard let f = try? AVAudioFile(forReading: url) else { status = "Formato non leggibile: \(url.lastPathComponent)"; return }
        let d = Double(f.length) / f.processingFormat.sampleRate
        items.append(MedleyItem(url: url, duration: d, end: d))
    }

    /// Mixdown offline: ogni brano viene convertito a 44,1 kHz stereo, tagliato, sfumato e sovrapposto.
    func render() throws -> RenderedAudio {
        let sr = 44100.0
        var L: [Float] = [], R: [Float] = []
        var cursor = 0
        for (i, it) in items.enumerated() {
            let a = try Self.decodeStereo(it.url, sr: sr, from: it.start, to: it.end)
            var l = a.0, r = a.1
            let g = Float(pow(10, it.gainDb / 20))
            for k in l.indices { l[k] *= g; r[k] *= g }
            Mastering.fade(&l, &r, inSamples: Int(it.fadeIn * sr), outSamples: Int(it.fadeOut * sr))
            let needed = cursor + l.count
            if L.count < needed { L += [Float](repeating: 0, count: needed - L.count); R += [Float](repeating: 0, count: needed - R.count) }
            for k in 0..<l.count { L[cursor + k] += l[k]; R[cursor + k] += r[k] }
            let overlap = i < items.count - 1 ? min(it.crossfade, (it.end - it.start) / 2) : 0
            cursor = needed - Int(overlap * sr)
            DispatchQueue.main.async { self.progress = Double(i + 1) / Double(self.items.count) * 0.8 }
        }
        if normalize { Mastering.master(&L, &R, sr: sr, mode: .natural, applyEQ: false) }
        else { Mastering.limit(&L, &R, sr: sr, from: 0, to: L.count, ceiling: 0.95) }
        return RenderedAudio(left: L, right: R, sampleRate: sr)
    }

    static func decodeStereo(_ url: URL, sr: Double, from: Double, to: Double) throws -> ([Float], [Float]) {
        let file = try AVAudioFile(forReading: url)
        let inFmt = file.processingFormat
        let outFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        guard let conv = AVAudioConverter(from: inFmt, to: outFmt) else { throw RenderError.engine("convertitore") }
        file.framePosition = AVAudioFramePosition(from * inFmt.sampleRate)
        var remaining = AVAudioFramePosition(max(0, to - from) * inFmt.sampleRate)
        let cap: AVAudioFrameCount = 32768
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: cap) else { return ([], []) }
        var L: [Float] = [], R: [Float] = []
        var eof = false
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 32768) else { break }
            var err: NSError?
            let st = conv.convert(to: out, error: &err) { _, s in
                if eof || remaining <= 0 { eof = true; s.pointee = .endOfStream; return nil }
                let n = AVAudioFrameCount(min(AVAudioFramePosition(cap), remaining))
                do { try file.read(into: inBuf, frameCount: n) } catch { eof = true; s.pointee = .endOfStream; return nil }
                if inBuf.frameLength == 0 { eof = true; s.pointee = .endOfStream; return nil }
                remaining -= AVAudioFramePosition(inBuf.frameLength)
                s.pointee = .haveData
                return inBuf
            }
            if let d = out.floatChannelData, out.frameLength > 0 {
                let n = Int(out.frameLength)
                L.append(contentsOf: UnsafeBufferPointer(start: d[0], count: n))
                R.append(contentsOf: UnsafeBufferPointer(start: outFmt.channelCount > 1 ? d[1] : d[0], count: n))
            }
            if st == .endOfStream || st == .error || out.frameLength == 0 { break }
        }
        return (L, R)
    }

    func export(to url: URL, format: ExportFormat) {
        busy = true; progress = 0; status = "Creo il medley…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let a = try self.render()
                try AudioExporter.write(a, to: url, format: format) { p in DispatchQueue.main.async { self.progress = 0.8 + p * 0.2 } }
                DispatchQueue.main.async {
                    self.busy = false
                    self.status = "Medley salvato: \(url.lastPathComponent) · \(formatTime(a.duration))"
                }
            } catch {
                DispatchQueue.main.async { self.busy = false; self.status = error.localizedDescription }
            }
        }
    }
}

// MARK: - Schede audio (CoreAudio)

struct AudioDevice: Identifiable, Hashable {
    var id: AudioDeviceID
    var name: String
    var inputs: Int
    var outputs: Int
}

enum AudioDevices {
    static func all() -> [AudioDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { AudioDevice(id: $0, name: name($0), inputs: channels($0, input: true), outputs: channels($0, input: false)) }
    }

    static func name(_ id: AudioDeviceID) -> String {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr, let s = cf?.takeRetainedValue() else { return "Dispositivo \(id)" }
        return s as String
    }

    static func channels(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Imposta la scheda usata da un motore (va fatto a motore fermo).
    @discardableResult
    static func use(_ id: AudioDeviceID, on unit: AudioUnit?) -> Bool {
        guard let unit = unit else { return false }
        var dev = id
        return AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
    }
}

// MARK: - Registrazione voce e base (I03), anche con scheda audio esterna

final class VoiceRecorder: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case voice, voiceAndBase
        var id: String { rawValue }
        var label: String { self == .voice ? "Solo voce" : "Voce + base (file mixato e tracce separate)" }
    }

    @Published private(set) var recording = false
    @Published private(set) var lastFile: URL?
    @Published var status = ""
    @Published var mode: Mode = .voiceAndBase
    @Published private(set) var devices: [AudioDevice] = []
    @Published var inputDevice: AudioDeviceID = 0          // 0 = predefinito di sistema
    @Published var monitorDevice: AudioDeviceID = 0
    @Published var mainOutputDevice: AudioDeviceID = 0
    @Published var monitor = true { didSet { monitorMixer.outputVolume = monitor ? Float(monitorVolume) : 0 } }
    @Published var monitorVolume: Double = 0.9 { didSet { monitorMixer.outputVolume = monitor ? Float(monitorVolume) : 0 } }
    @Published var voiceGain: Double = 1.0
    @Published var level: Double = 0

    private var engine = AVAudioEngine()
    private let monitorMixer = AVAudioMixerNode()
    private var voiceFile: AVAudioFile?
    private var baseFile: AVAudioFile?
    private var voiceURL: URL?
    private var baseURL: URL?
    private var stem = ""

    var folder: URL {
        let u = AppPaths.exports.appendingPathComponent("Registrazioni", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    init() { refreshDevices() }

    func refreshDevices() { devices = AudioDevices.all() }
    var inputs: [AudioDevice] { devices.filter { $0.inputs > 0 } }
    var outputs: [AudioDevice] { devices.filter { $0.outputs > 0 } }

    /// Uscita della base (karaoke, Atomix…): per esempio la scheda audio esterna verso il mixer live o le cuffie.
    func applyMainOutput() {
        guard mainOutputDevice != 0 else { return }
        let hub = AudioHub.shared
        hub.engine.stop()
        AudioDevices.use(mainOutputDevice, on: hub.engine.outputNode.audioUnit)
        hub.start()
        NotificationCenter.default.post(name: AudioHub.restartedNotification, object: nil)
        status = "Uscita della base: \(AudioDevices.name(mainOutputDevice))"
    }

    func toggle(songTitle: String?) { recording ? stop() : start(songTitle: songTitle) }

    private func start(songTitle: String?) {
        guard AVCaptureDevice.authorizationStatus(for: .audio) != .denied else {
            status = "Consenti il microfono in Impostazioni di Sistema → Privacy e sicurezza → Microfono."; return
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                guard ok else { self.status = "Accesso al microfono negato."; return }
                self.begin(songTitle: songTitle)
            }
        }
    }

    private func begin(songTitle: String?) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        stem = ((songTitle ?? "Registrazione") + " - " + f.string(from: Date())).replacingOccurrences(of: "/", with: "-")
        engine = AVAudioEngine()
        if inputDevice != 0 { AudioDevices.use(inputDevice, on: engine.inputNode.audioUnit) }
        if monitorDevice != 0 { AudioDevices.use(monitorDevice, on: engine.outputNode.audioUnit) }
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.channelCount > 0, fmt.sampleRate > 0 else { status = "La scheda scelta non ha ingressi attivi."; return }
        // Ascolto in cuffia della voce (latenza minima, senza effetti).
        engine.attach(monitorMixer)
        engine.connect(input, to: monitorMixer, format: fmt)
        engine.connect(monitorMixer, to: engine.mainMixerNode, format: fmt)
        monitorMixer.outputVolume = monitor ? Float(monitorVolume) : 0
        do {
            let vURL = folder.appendingPathComponent(stem + " - voce.wav")
            voiceFile = try AVAudioFile(forWriting: vURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate,
                                                                    AVNumberOfChannelsKey: fmt.channelCount, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false])
            voiceURL = vURL
            input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
                try? self?.voiceFile?.write(from: buf)
                if let d = buf.floatChannelData?[0] {
                    var pk: Float = 0
                    for i in 0..<Int(buf.frameLength) { pk = max(pk, abs(d[i])) }
                    DispatchQueue.main.async { self?.level = Double(pk) }
                }
            }
            if mode == .voiceAndBase {
                let hub = AudioHub.shared
                hub.start()
                let bfmt = hub.engine.mainMixerNode.outputFormat(forBus: 0)
                let bURL = folder.appendingPathComponent(stem + " - base.wav")
                baseFile = try AVAudioFile(forWriting: bURL, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: bfmt.sampleRate,
                                                                       AVNumberOfChannelsKey: bfmt.channelCount, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false])
                baseURL = bURL
                hub.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: bfmt) { [weak self] buf, _ in try? self?.baseFile?.write(from: buf) }
            }
            try engine.start()
            recording = true
            lastFile = vURL
            status = "Registro" + (mode == .voiceAndBase ? " voce e base" : " la voce") + (monitor ? " · ascolto in cuffia attivo" : "")
        } catch {
            status = "Registrazione non avviata: \(error.localizedDescription)"
            cleanup()
        }
    }

    private func cleanup() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if baseFile != nil { AudioHub.shared.engine.mainMixerNode.removeTap(onBus: 0) }
        voiceFile = nil; baseFile = nil
        recording = false
        level = 0
    }

    private func stop() {
        let hadBase = baseFile != nil
        cleanup()
        guard let v = voiceURL else { return }
        guard hadBase, let b = baseURL else { status = "Salvata: \(v.lastPathComponent)"; return }
        status = "Unisco voce e base…"
        let mixURL = folder.appendingPathComponent(stem + " - mix.wav")
        let gain = Float(voiceGain)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let bd = AVAudioFile.duration(b), vd = AVAudioFile.duration(v)
                let (bl, br) = try MedleyCreator.decodeStereo(b, sr: 44100, from: 0, to: bd)
                let (vl, vr) = try MedleyCreator.decodeStereo(v, sr: 44100, from: 0, to: vd)
                let n = max(bl.count, vl.count)
                var L = [Float](repeating: 0, count: n), R = [Float](repeating: 0, count: n)
                for i in 0..<bl.count { L[i] += bl[i]; R[i] += br[i] }
                // La voce (spesso mono sul canale 1 della scheda) va al centro.
                for i in 0..<vl.count { let m = (vl[i] + vr[i]) * 0.5 * gain; L[i] += m; R[i] += m }
                Mastering.limit(&L, &R, sr: 44100, from: 0, to: n, ceiling: 0.95)
                try AudioExporter.write(RenderedAudio(left: L, right: R, sampleRate: 44100), to: mixURL, format: .wav)
                DispatchQueue.main.async {
                    self.lastFile = mixURL
                    self.status = "Salvati: mix, voce e base separati (\(mixURL.deletingPathExtension().lastPathComponent))"
                }
            } catch {
                DispatchQueue.main.async { self.status = "Voce e base salvate separate; mix non riuscito: \(error.localizedDescription)" }
            }
        }
    }
}

extension AVAudioFile {
    static func duration(_ u: URL) -> Double {
        guard let f = try? AVAudioFile(forReading: u) else { return 0 }
        return Double(f.length) / f.processingFormat.sampleRate
    }
}
