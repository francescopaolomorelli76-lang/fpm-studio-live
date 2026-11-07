import Foundation
import AVFoundation
import AudioToolbox
import os

/// Sintetizzatore General MIDI multitimbrico di macOS (DLSMusicDevice) che carica SoundFont .sf2 e .dls.
/// Qui si carica il SoundFont di Win Live (o un altro) dal disco dell'utente.
final class GMSynth {
    let node: AVAudioUnitMIDIInstrument
    var audioUnit: AudioUnit { node.audioUnit }
    private(set) var soundBankName = "Suoni di sistema (Apple GS)"

    init() {
        let desc = AudioComponentDescription(componentType: kAudioUnitType_MusicDevice,
                                             componentSubType: kAudioUnitSubType_DLSSynth,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        node = AVAudioUnitMIDIInstrument(audioComponentDescription: desc)
    }

    /// Carica un SoundFont (.sf2/.sf3) o DLS. `nil` = suoni di sistema.
    @discardableResult
    func loadSoundBank(_ url: URL?) -> Bool {
        guard let url = url, FileManager.default.fileExists(atPath: url.path) else { return false }
        var cfURL = url as CFURL
        let st = AudioUnitSetProperty(audioUnit, kMusicDeviceProperty_SoundBankURL, kAudioUnitScope_Global, 0,
                                      &cfURL, UInt32(MemoryLayout<CFURL>.size))
        if st == noErr { soundBankName = url.deletingPathExtension().lastPathComponent }
        return st == noErr
    }

    func setInternalReverb(_ on: Bool) {
        var v: UInt32 = on ? 1 : 0
        AudioUnitSetProperty(audioUnit, kMusicDeviceProperty_UsesInternalReverb, kAudioUnitScope_Global, 0, &v, UInt32(MemoryLayout<UInt32>.size))
    }

    @inline(__always)
    func send(_ status: UInt8, _ d1: UInt8, _ d2: UInt8, offset: UInt32 = 0) {
        MusicDeviceMIDIEvent(audioUnit, UInt32(status), UInt32(d1), UInt32(d2), offset)
    }

    func allSoundOff() {
        for ch in 0..<16 {
            send(0xB0 | UInt8(ch), 64, 0)
            send(0xB0 | UInt8(ch), 123, 0)
            send(0xB0 | UInt8(ch), 120, 0)
        }
    }
}

/// Sequencer MIDI con precisione al campione: gli eventi vengono inviati al sintetizzatore
/// dalla notifica di rendering audio, con l'offset esatto dentro il buffer.
/// Gestisce tono, tempo, mute/solo, volume per canale e salto di posizione.
final class MIDISequencer {
    struct Ev {
        var time: Double     // secondi a velocità originale
        var status: UInt8
        var d1: UInt8
        var d2: UInt8
    }

    let synth: GMSynth
    private(set) var events: [Ev] = []
    private(set) var duration: Double = 0
    private var index = 0
    private var lock = os_unfair_lock()

    // Stato condiviso con il thread audio (protetto da `lock`).
    private var _position: Double = 0
    private var _playing = false
    private var pendingSeek: Double?
    private var pendingCommands: [(UInt8, UInt8, UInt8)] = []
    private var sentPitch = [[Int16]](repeating: [Int16](repeating: -1, count: 128), count: 16)
    private var channelVolume = [UInt8](repeating: 100, count: 16)
    private var endNotified = false

    var sampleRate: Double = 44100
    var speed: Double = 1
    var transpose: Int = 0
    private(set) var muted = [Bool](repeating: false, count: 16)
    private(set) var gains = [Double](repeating: 1, count: 16)
    /// Chiamato (sul thread principale) quando il brano finisce.
    var onEnd: (() -> Void)?
    /// Durata del "coda" dopo l'ultimo evento prima di dichiarare la fine.
    var tail: Double = 1.5

    private static let renderNotify: AURenderCallback = { refCon, flags, _, _, frames, _ in
        if flags.pointee.contains(.unitRenderAction_PreRender) {
            Unmanaged<MIDISequencer>.fromOpaque(refCon).takeUnretainedValue().renderSlice(frames: frames)
        }
        return noErr
    }

    init(synth: GMSynth) {
        self.synth = synth
        AudioUnitAddRenderNotify(synth.audioUnit, MIDISequencer.renderNotify, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        AudioUnitRemoveRenderNotify(synth.audioUnit, MIDISequencer.renderNotify, Unmanaged.passUnretained(self).toOpaque())
    }

    var position: Double {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return pendingSeek ?? _position
    }
    var isPlaying: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return _playing
    }

    func load(_ midi: MIDIFile) {
        var evs: [Ev] = []
        evs.reserveCapacity(midi.events.count)
        for e in midi.events {
            if case .channel(let s, let d1, let d2) = e.kind {
                evs.append(Ev(time: midi.seconds(atTick: e.tick), status: s, d1: d1, d2: d2))
            }
        }
        withLock {
            _playing = false
            events = evs
            duration = midi.duration
            index = 0
            _position = 0
            pendingSeek = nil
            endNotified = false
            channelVolume = [UInt8](repeating: 100, count: 16)
            muted = [Bool](repeating: false, count: 16)
            gains = [Double](repeating: 1, count: 16)
        }
        synth.allSoundOff()
        resetControllers()
    }

    private func resetControllers() {
        for ch in 0..<16 {
            synth.send(0xB0 | UInt8(ch), 121, 0)   // reset controller
            synth.send(0xB0 | UInt8(ch), 7, 100)
            synth.send(0xB0 | UInt8(ch), 10, 64)
            synth.send(0xC0 | UInt8(ch), 0, 0)
        }
    }

    @inline(__always) private func withLock<T>(_ f: () -> T) -> T {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return f()
    }

    func play() { withLock { _playing = true; endNotified = false } }
    func pause() {
        withLock { _playing = false }
        synth.allSoundOff()
        withLock { sentPitch = [[Int16]](repeating: [Int16](repeating: -1, count: 128), count: 16) }
    }
    func seek(to seconds: Double) {
        withLock { pendingSeek = max(0, min(seconds, duration)); endNotified = false }
    }

    func setMuted(_ ch: Int, _ m: Bool) {
        withLock {
            muted[ch] = m
            if m { pendingCommands.append((0xB0 | UInt8(ch), 123, 0)); pendingCommands.append((0xB0 | UInt8(ch), 120, 0)) }
        }
    }
    func setGain(_ ch: Int, _ g: Double) {
        withLock {
            gains[ch] = g
            pendingCommands.append((0xB0 | UInt8(ch), 7, UInt8(min(127, Double(channelVolume[ch]) * g))))
        }
    }
    func setTranspose(_ semis: Int) { withLock { transpose = semis } }

    // MARK: - Thread audio

    private func renderSlice(frames: UInt32) {
        guard os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }
        for c in pendingCommands { synth.send(c.0, c.1, c.2) }
        pendingCommands.removeAll(keepingCapacity: true)

        if let s = pendingSeek {
            pendingSeek = nil
            for ch in 0..<16 { synth.send(0xB0 | UInt8(ch), 64, 0); synth.send(0xB0 | UInt8(ch), 123, 0); synth.send(0xB0 | UInt8(ch), 120, 0) }
            for ch in 0..<16 { for p in 0..<128 { sentPitch[ch][p] = -1 } }
            // Ricostruisco programmi e controller fino al punto di arrivo.
            var i = 0
            while i < events.count && events[i].time < s {
                let e = events[i]
                let cmd = e.status & 0xF0
                if cmd == 0xC0 || cmd == 0xE0 || (cmd == 0xB0 && e.d1 != 64 && e.d1 != 123 && e.d1 != 120) {
                    dispatch(e, offset: 0)
                }
                i += 1
            }
            index = i
            _position = s
        }
        guard _playing else { return }
        let dt = Double(frames) / sampleRate * speed
        let end = _position + dt
        while index < events.count && events[index].time < end {
            let e = events[index]
            let off = UInt32(max(0, min(Double(frames - 1), (e.time - _position) / speed * sampleRate)))
            dispatch(e, offset: off)
            index += 1
        }
        _position = end
        if index >= events.count && _position > duration + tail && !endNotified {
            endNotified = true
            _playing = false
            let cb = onEnd
            DispatchQueue.main.async { cb?() }
        }
    }

    @inline(__always) private func dispatch(_ e: Ev, offset: UInt32) {
        let ch = Int(e.status & 0x0F)
        let cmd = e.status & 0xF0
        switch cmd {
        case 0x90 where e.d2 > 0:
            if muted[ch] { return }
            let p = ch == 9 ? Int(e.d1) : Int(e.d1) + transpose
            guard p >= 0 && p < 128 else { return }
            if sentPitch[ch][Int(e.d1)] >= 0 { synth.send(0x80 | UInt8(ch), UInt8(sentPitch[ch][Int(e.d1)]), 0, offset: offset) }
            sentPitch[ch][Int(e.d1)] = Int16(p)
            synth.send(e.status, UInt8(p), e.d2, offset: offset)
        case 0x80, 0x90:
            let sp = sentPitch[ch][Int(e.d1)]
            if sp >= 0 {
                synth.send(0x80 | UInt8(ch), UInt8(sp), 0, offset: offset)
                sentPitch[ch][Int(e.d1)] = -1
            }
        case 0xA0:
            let p = ch == 9 ? Int(e.d1) : Int(e.d1) + transpose
            if p >= 0 && p < 128 { synth.send(e.status, UInt8(p), e.d2, offset: offset) }
        case 0xB0 where e.d1 == 7:
            channelVolume[ch] = e.d2
            synth.send(e.status, 7, UInt8(min(127, Double(e.d2) * gains[ch])), offset: offset)
        default:
            synth.send(e.status, e.d1, e.d2, offset: offset)
        }
    }
}
