import Foundation
import AVFoundation

/// Microfono con riverbero ed eco in tempo reale (motore separato: se il microfono
/// ha problemi la musica continua a suonare).
final class MicEngine: ObservableObject {
    @Published var enabled = false { didSet { enabled ? start() : stop() } }
    @Published var volume: Double = 0.8 { didSet { mixer.outputVolume = Float(volume) } }
    @Published var reverb: Double = 30 { didSet { reverbUnit.wetDryMix = Float(reverb) } }
    @Published var echo: Double = 15 { didSet { delayUnit.wetDryMix = Float(echo) } }
    @Published var echoTime: Double = 0.28 { didSet { delayUnit.delayTime = echoTime } }
    @Published var level: Double = 0
    @Published var error: String?

    private let engine = AVAudioEngine()
    private let reverbUnit = AVAudioUnitReverb()
    private let delayUnit = AVAudioUnitDelay()
    private let eq = AVAudioUnitEQ(numberOfBands: 2)
    private let mixer = AVAudioMixerNode()
    private var configured = false

    private func configure() {
        guard !configured else { return }
        configured = true
        let nodes: [AVAudioNode] = [eq, delayUnit, reverbUnit, mixer]
        nodes.forEach { engine.attach($0) }
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        // Voce: taglio dei bassi e presenza.
        eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 90; eq.bands[0].bypass = false
        eq.bands[1].filterType = .parametric; eq.bands[1].frequency = 3500; eq.bands[1].gain = 2.5; eq.bands[1].bandwidth = 1.2; eq.bands[1].bypass = false
        reverbUnit.loadFactoryPreset(.plate)
        reverbUnit.wetDryMix = Float(reverb)
        delayUnit.delayTime = echoTime
        delayUnit.feedback = 28
        delayUnit.lowPassCutoff = 6000
        delayUnit.wetDryMix = Float(echo)
        mixer.outputVolume = Float(volume)
        engine.connect(input, to: eq, format: fmt)
        engine.connect(eq, to: delayUnit, format: fmt)
        engine.connect(delayUnit, to: reverbUnit, format: fmt)
        engine.connect(reverbUnit, to: mixer, format: fmt)
        engine.connect(mixer, to: engine.mainMixerNode, format: nil)
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            guard let d = buf.floatChannelData?[0] else { return }
            var peak: Float = 0
            for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[i])) }
            DispatchQueue.main.async { self?.level = Double(peak) }
        }
    }

    private func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async {
                    if ok { self.startEngine() } else { self.error = "Accesso al microfono negato."; self.enabled = false }
                }
            }
        default:
            error = "Consenti il microfono in Impostazioni di Sistema → Privacy e sicurezza → Microfono."
            enabled = false
        }
    }

    private func startEngine() {
        configure()
        do { try engine.start(); error = nil }
        catch { self.error = "Microfono non disponibile: \(error.localizedDescription)"; enabled = false }
    }

    private func stop() {
        engine.stop()
        level = 0
    }
}
