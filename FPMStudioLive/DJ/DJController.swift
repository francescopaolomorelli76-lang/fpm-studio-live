import Foundation
import SwiftUI

/// Due deck, crossfader e AUTOMIX con un pulsante: alla fine di ogni brano
/// parte il successivo della playlist con dissolvenza incrociata (anche basi MIDI).
final class DJController: ObservableObject {
    let deckA: Deck
    let deckB: Deck
    @Published var crossfader: Double = 0 { didSet { applyCrossfader() } }   // -1 = A, +1 = B
    @Published var playlist: [URL] = [] { didSet { savePlaylist() } }
    @Published var automix = false { didSet { if automix && !automixSilently { startAutomix() } } }
    private var automixSilently = false
    @Published var crossfadeSeconds: Double = 8
    @Published var syncTempo = true
    @Published private(set) var status = ""
    @Published private(set) var nextIndex = 0

    var soundBank: () -> String = { "" }
    private var timer: Timer?
    private var fading = false

    init() {
        let hub = AudioHub.shared
        deckA = Deck(id: "A", nodes: hub.deckA)
        deckB = Deck(id: "B", nodes: hub.deckB)
        applyCrossfader()
        if let d = UserDefaults.standard.array(forKey: "djPlaylist") as? [String] {
            playlist = d.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        deckA.onEnd = { [weak self] in self?.deckEnded(self?.deckA) }
        deckB.onEnd = { [weak self] in self?.deckEnded(self?.deckB) }
    }

    private func savePlaylist() { UserDefaults.standard.set(playlist.map { $0.path }, forKey: "djPlaylist") }

    /// Crossfader a potenza costante.
    private func applyCrossfader() {
        let x = (crossfader + 1) / 2
        deckA.crossfadeGain = cos(x * .pi / 2)
        deckB.crossfadeGain = sin(x * .pi / 2)
    }

    func load(_ url: URL, into deck: Deck) {
        deck.load(url, soundBank: soundBank())
    }

    var activeDeck: Deck? {
        if deckA.isPlaying && (!deckB.isPlaying || crossfader <= 0) { return deckA }
        if deckB.isPlaying { return deckB }
        return nil
    }

    private func other(_ d: Deck) -> Deck { d === deckA ? deckB : deckA }

    private func tick() {
        deckA.updatePosition()
        deckB.updatePosition()
        guard automix, !fading, let active = activeDeck else { return }
        let next = other(active)
        // Prepara in anticipo il brano successivo sull'altro deck.
        if next.url == nil || (!next.isPlaying && next.position >= next.duration - 1) || next.duration == 0 {
            if !next.loading, nextIndex < playlist.count, next.url != playlist[nextIndex] {
                next.load(playlist[nextIndex], soundBank: soundBank())
            }
        }
        // Inizio un po' prima per avere il tempo di aspettare il primo tempo della battuta.
        if active.remaining <= crossfadeSeconds + (syncTempo ? 2.5 : 0) && !next.loading && next.url != nil && !next.isPlaying {
            startTransition(from: active, to: next)
        }
    }

    func startAutomix() {
        guard !playlist.isEmpty else { status = "Aggiungi brani alla playlist"; automix = false; return }
        if activeDeck == nil {
            let d = crossfader <= 0 ? deckA : deckB
            nextIndex = min(nextIndex, playlist.count - 1)
            status = "Automix: carico \(playlist[nextIndex].deletingPathExtension().lastPathComponent)…"
            let idx = nextIndex
            d.load(playlist[idx], soundBank: soundBank()) { [weak self] in
                guard let self = self else { return }
                self.crossfader = d === self.deckA ? -1 : 1
                d.play()
                self.nextIndex = idx + 1
                self.status = "Automix attivo"
            }
        } else {
            status = "Automix attivo"
        }
    }

    /// Pulsante unico ATOMIX: se non suona niente parte il primo brano; se un brano suona, sfuma e passa al successivo.
    /// Da quel momento il mix continua da solo a ogni fine brano finché ci sono brani in coda.
    func atomix() {
        if activeDeck == nil {
            if let ready = [deckA, deckB].first(where: { $0.url != nil && !$0.loading }) {
                crossfader = ready === deckA ? -1 : 1
                ready.play()
                if !automix { automixSilently = true; automix = true; automixSilently = false }
                status = "ATOMIX: in onda \(ready.title)"
            } else {
                automix = true   // carica e fa partire il primo della playlist
            }
            return
        }
        if !automix { automixSilently = true; automix = true; automixSilently = false }
        mixNow()
    }

    /// Pulsante MIX: dal brano che suona a quello in attesa sull'altro deck.
    /// Se l'altro deck è vuoto carica il prossimo della playlist; se non suona niente, fa partire il deck pronto.
    func mixNow() {
        guard let active = activeDeck else {
            if let ready = [deckA, deckB].first(where: { $0.url != nil && !$0.loading }) {
                crossfader = ready === deckA ? -1 : 1
                ready.play()
                status = "In onda: \(ready.title)"
            } else if !playlist.isEmpty {
                automix = true
            } else {
                status = "Carica un brano in un deck o nella playlist"
            }
            return
        }
        let next = other(active)
        if next.loading { status = "Attendi: sto preparando \(next.title)…"; return }
        if next.url == nil || next.isPlaying {
            guard nextIndex < playlist.count else { status = "Nessun brano in attesa: caricane uno nell'altro deck"; return }
            status = "Preparo \(playlist[nextIndex].deletingPathExtension().lastPathComponent)…"
            next.load(playlist[nextIndex], soundBank: soundBank()) { [weak self] in self?.startTransition(from: active, to: next) }
        } else {
            startTransition(from: active, to: next)
        }
    }

    /// Mix: se "Allinea BPM e battuta" è attivo, il brano in attesa prende il tempo di quello che suona
    /// e parte esattamente sul prossimo "uno" di battuta; poi parte la dissolvenza.
    private func startTransition(from a: Deck, to b: Deck) {
        guard !fading, b.url != nil else { return }
        fading = true
        var delay = 0.0
        let entry = b.firstDownbeat
        if syncTempo {
            b.sync(to: a)
            a.updatePosition()
            if let beat = a.nextDownbeat(after: a.position + 0.25) {
                delay = max(0, (beat - a.position) / a.rate)
                if delay > 6 { delay = 0 }   // analisi incerta: niente attese lunghe
            }
        }
        b.seek(to: entry)
        b.play(after: delay)
        if let u = b.url, let i = playlist.firstIndex(of: u) { nextIndex = i + 1 }
        status = "Mix: \(a.title) → \(b.title)" + (syncTempo && b.bpm != nil ? " · a tempo (\(Int((b.effectiveBPM ?? 0).rounded())) BPM)" : "")
        let target: Double = b === deckA ? -1 : 1
        let startX = crossfader
        let steps = max(1, Int(crossfadeSeconds * 20))
        var k = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            Timer.scheduledTimer(withTimeInterval: self.crossfadeSeconds / Double(steps), repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                k += 1
                let f = Double(k) / Double(steps)
                // Curva morbida (smoothstep): il tempo resta allineato per tutta la dissolvenza.
                let s = f * f * (3 - 2 * f)
                self.crossfader = startX + (target - startX) * s
                if k >= steps {
                    t.invalidate()
                    a.unload()
                    self.fading = false
                    self.status = self.automix ? "Automix attivo" : "In onda: \(b.title)"
                    self.returnToOriginalTempo(b)
                }
            }
        }
    }

    /// Finito il mix, il brano torna piano piano (15 s) al suo tempo originale.
    private func returnToOriginalTempo(_ d: Deck) {
        guard abs(d.pitchPercent) > 0.05 else { return }
        let start = d.pitchPercent
        var k = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            k += 1
            d.pitchPercent = start * (1 - Double(k) / 150)
            if k >= 150 || !d.isPlaying { t.invalidate(); if d.isPlaying { d.pitchPercent = 0 } }
        }
    }

    private func deckEnded(_ d: Deck?) {
        guard let d = d, automix, !fading else { return }
        let next = other(d)
        if !next.isPlaying, next.url != nil, !next.loading { startTransition(from: d, to: next) }
    }
}
