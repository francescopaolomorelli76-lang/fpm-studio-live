import Foundation
import AppKit

/// Marker, loop, eventi temporizzati, fade out, modalità canali e leggio.
extension KaraokePlayer {

    func loadAdvanced(_ side: SongSidecar?, for url: URL) {
        markers = side?.markers ?? []
        events = side?.events ?? []
        activeLoop = nil
        loopRemaining = 0
        banner = nil
        pdfPage = 1
        songVolume = 1
        lastEventTime = 0
        fadeTimer?.invalidate()
        // Documento per il leggio: indicato nel file del brano, oppure PDF/TXT con lo stesso nome.
        if let p = side?.documentPath, FileManager.default.fileExists(atPath: p) {
            documentURL = URL(fileURLWithPath: p)
        } else {
            documentURL = ["pdf", "txt", "rtf"].map { url.deletingPathExtension().appendingPathExtension($0) }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }

    // MARK: Eventi

    func advancedTick() {
        let t = position
        // Salto indietro (seek/loop): ricalcolo lo stato, nessun evento rieseguito.
        if t + 0.25 < lastEventTime { resyncEvents(at: t); return }
        if isPlaying {
            for e in EventTimeline.due(from: lastEventTime, to: t, events: events) { fire(e) }
        }
        lastEventTime = t
        // Loop attivo.
        if isPlaying, let id = activeLoop, let m = markers.first(where: { $0.id == id }), let end = m.loopEnd, t >= end {
            if m.repeats == 0 || loopRemaining > 1 {
                if m.repeats > 0 { loopRemaining -= 1 }
                seek(to: m.time)
            } else {
                activeLoop = nil
                loopRemaining = 0
            }
        }
    }

    /// Stato deterministico dopo seek/loop (tono, tempo, volume, messaggio, pagina, metronomo).
    func resyncEvents(at t: Double) {
        lastEventTime = t
        guard !events.isEmpty else { return }
        let st = EventTimeline.state(at: t, events: events)
        let side = item.flatMap { SongSidecar.load(for: $0.url) }
        transpose = st.transpose ?? side?.defaultTranspose ?? transpose
        if let tp = st.tempo { tempo = tp }
        songVolume = st.volume ?? 1
        banner = st.message
        if let p = st.pdfPage { pdfPage = p }
        if let m = st.metronome { metronome = m }
    }

    private func fire(_ e: LiveEvent) {
        switch e.kind {
        case .keyChange: transpose = Int(e.value.rounded()).clamped(-12, 12)
        case .tempoChange: tempo = (e.value / 100).clamped(0.5, 1.5)
        case .songVolume: songVolume = (e.value / 100).clamped(0, 1.5)
        case .fadeOut: fadeOut(seconds: max(0.5, e.value))
        case .message: banner = e.text
        case .clearMessage: banner = nil
        case .jumpToMarker:
            if let m = markers.first(where: { $0.name.lowercased() == e.text.lowercased() }) { seek(to: m.time) }
        case .pdfPage: pdfPage = max(1, Int(e.value.rounded()))
        case .metronomeOn: metronome = true
        case .metronomeOff: metronome = false
        case .playSample: onPlaySample?(Int(e.value.rounded()))
        case .nextSong: playNextNow()
        }
    }

    func addEvent(_ kind: LiveEvent.Kind) {
        var e = LiveEvent(time: position, kind: kind)
        switch kind {
        case .keyChange: e.value = Double(transpose + 1)
        case .tempoChange: e.value = (tempo * 100).rounded()
        case .songVolume: e.value = 80
        case .fadeOut: e.value = 4
        case .pdfPage: e.value = Double(pdfPage + 1)
        case .playSample: e.value = 1
        case .message: e.text = "Tutti insieme!"
        case .jumpToMarker: e.text = markers.first?.name ?? ""
        default: break
        }
        events.append(e)
        events.sort { $0.time < $1.time }
    }

    // MARK: Marker e loop

    /// Quick save: marker alla posizione attuale (massimo 10).
    @discardableResult
    func addMarker() -> Bool {
        guard markers.count < SongMarker.maxCount else { status = "Massimo \(SongMarker.maxCount) marker per brano"; return false }
        let name = currentSection?.title ?? "Marker \(markers.count + 1)"
        markers.append(SongMarker(name: name, time: position))
        markers.sort { $0.time < $1.time }
        return true
    }

    func jump(to m: SongMarker) { seek(to: m.time) }

    func toggleLoop(_ m: SongMarker) {
        if activeLoop == m.id { activeLoop = nil; loopRemaining = 0; return }
        guard m.loopEnd != nil else { status = "Imposta la fine del loop (pulsante \"Fine loop qui\")"; return }
        activeLoop = m.id
        loopRemaining = m.repeats
        if position < m.time || position > (m.loopEnd ?? 0) { seek(to: m.time) }
    }

    // MARK: Fade out e volume

    func fadeOut(seconds: Double = 4) {
        fadeTimer?.invalidate()
        let start = songVolume
        let steps = max(1, Int(seconds * 20))
        var k = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: seconds / Double(steps), repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            k += 1
            self.songVolume = start * (1 - Double(k) / Double(steps))
            if k >= steps {
                t.invalidate()
                self.pause()
                self.songVolume = 1
            }
        }
    }

    // MARK: Modalità canali (M, U, D, B, A, N)

    enum ChannelMode { case all, melodyOnly, drumsOnly, bassAndDrums, noMelody }

    func applyChannelMode(_ mode: ChannelMode) {
        guard kind == .midi else { return }
        for c in channels {
            let keep: Bool
            switch mode {
            case .all: keep = true
            case .melodyOnly: keep = c.channel == melodyChannel
            case .drumsOnly: keep = c.channel == 9
            case .bassAndDrums: keep = c.channel == 9 || bassChannels.contains(c.channel)
            case .noMelody: keep = c.channel != melodyChannel
            }
            setMuted(c.channel, !keep)
            if c.solo { setSolo(c.channel, false) }
        }
    }

    /// N: ripristina volumi, mute e solo di tutti i canali.
    func resetChannels() {
        for c in channels {
            setMuted(c.channel, false)
            setSolo(c.channel, false)
            setGain(c.channel, 1)
        }
    }

    func resetTempo() { tempo = 1 }
    func tempoStep(_ d: Double) { tempo = (tempo + d).clamped(0.6, 1.4) }
}
