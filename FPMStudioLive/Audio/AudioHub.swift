import Foundation
import AVFoundation

/// Grafo audio unico dell'app:
///
///   synth (SoundFont) → EQ → riverbero ─┐
///   lettore file (mp3/video) → tono/tempo ┴→ karaoke ─┐
///   deck A → tono/tempo → EQ → volume ─────────────────┼→ uscita
///   deck B → tono/tempo → EQ → volume ─────────────────┘
final class AudioHub {
    static let shared = AudioHub()

    let engine = AVAudioEngine()
    let synth = GMSynth()
    lazy var sequencer = MIDISequencer(synth: synth)
    let synthEQ = AVAudioUnitEQ(numberOfBands: 4)
    let synthReverb = AVAudioUnitReverb()
    let filePlayer = AVAudioPlayerNode()
    let fileTimePitch = AVAudioUnitTimePitch()
    let karaokeMixer = AVAudioMixerNode()
    let djMixer = AVAudioMixerNode()
    private(set) var deckA: DeckNodes!
    private(set) var deckB: DeckNodes!
    private(set) var started = false
    var lastError: String?

    struct DeckNodes {
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let volume = AVAudioMixerNode()
    }

    private init() {
        let e = engine
        let format = e.outputNode.outputFormat(forBus: 0)
        let sr = format.sampleRate > 0 ? format.sampleRate : 44100
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!

        let nodes: [AVAudioNode] = [synth.node, synthEQ, synthReverb, filePlayer, fileTimePitch, karaokeMixer, djMixer]
        nodes.forEach { e.attach($0) }
        AudioHub.configureSynthEQ(synthEQ)
        synthReverb.loadFactoryPreset(.mediumHall)
        synthReverb.wetDryMix = 12

        e.connect(synth.node, to: synthEQ, format: stereo)
        e.connect(synthEQ, to: synthReverb, format: stereo)
        e.connect(synthReverb, to: karaokeMixer, format: stereo)
        e.connect(filePlayer, to: fileTimePitch, format: stereo)
        e.connect(fileTimePitch, to: karaokeMixer, format: stereo)
        e.connect(karaokeMixer, to: e.mainMixerNode, format: stereo)

        deckA = makeDeck(stereo)
        deckB = makeDeck(stereo)
        e.connect(djMixer, to: e.mainMixerNode, format: stereo)

        sequencer.sampleRate = sr
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            self?.restart()
        }
    }

    private func makeDeck(_ f: AVAudioFormat) -> DeckNodes {
        let d = DeckNodes()
        let nodes: [AVAudioNode] = [d.player, d.timePitch, d.eq, d.volume]
        nodes.forEach { engine.attach($0) }
        let bands = d.eq.bands
        bands[0].filterType = .lowShelf; bands[0].frequency = 120; bands[0].gain = 0
        bands[1].filterType = .parametric; bands[1].frequency = 1000; bands[1].bandwidth = 1.5; bands[1].gain = 0
        bands[2].filterType = .highShelf; bands[2].frequency = 7000; bands[2].gain = 0
        bands.forEach { $0.bypass = false }
        engine.connect(d.player, to: d.timePitch, format: f)
        engine.connect(d.timePitch, to: d.eq, format: f)
        engine.connect(d.eq, to: d.volume, format: f)
        engine.connect(d.volume, to: djMixer, format: f)
        return d
    }

    /// EQ "professionale" dell'app originale: taglio sotto 28 Hz, +4 dB a 90 Hz, -1,5 dB a 320 Hz, +2 dB a 8,5 kHz.
    static func configureSynthEQ(_ eq: AVAudioUnitEQ, enabled: Bool = true) {
        let b = eq.bands
        b[0].filterType = .highPass; b[0].frequency = 28; b[0].bandwidth = 0.7
        b[1].filterType = .lowShelf; b[1].frequency = 90; b[1].gain = 4
        b[2].filterType = .parametric; b[2].frequency = 320; b[2].bandwidth = 1.2; b[2].gain = -1.5
        b[3].filterType = .highShelf; b[3].frequency = 8500; b[3].gain = 2
        b.forEach { $0.bypass = !enabled }
    }

    func start() {
        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
            started = true
            lastError = nil
        } catch {
            lastError = "Audio non disponibile: \(error.localizedDescription)"
        }
    }

    private func restart() {
        engine.stop()
        start()
    }

    func loadSoundBank(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        return synth.loadSoundBank(URL(fileURLWithPath: path))
    }
}
