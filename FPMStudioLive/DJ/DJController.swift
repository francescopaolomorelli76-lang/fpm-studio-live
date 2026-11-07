import Foundation
import SwiftUI

/// Due deck, crossfader e AUTOMIX con un pulsante: alla fine di ogni brano
/// parte il successivo della playlist con dissolvenza incrociata (anche basi MIDI).
final class DJController: ObservableObject {
    let deckA: Deck
    let deckB: Deck
    @Published var crossfader: Double = 0 { didSet { applyCrossfader() } }   // -1 = A, +1 = B
    @Published var playlist: [URL] = [] { didSet { savePlaylist() } }
    @Published var automix = false { didSet { if automix { startAutomix() } } }
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
        if active.remaining <= crossfadeSeconds && !next.loading && next.url != nil && !next.isPlaying {
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

    /// Passa subito al brano successivo (pulsante "Mixa ora").
    func mixNow() {
        guard let active = activeDeck else { automix = true; return }
        let next = other(active)
        if next.url == nil || next.isPlaying, nextIndex < playlist.count {
            next.load(playlist[nextIndex], soundBank: soundBank()) { [weak self] in self?.startTransition(from: active, to: next) }
        } else {
            startTransition(from: active, to: next)
        }
    }

    private func startTransition(from a: Deck, to b: Deck) {
        guard !fading else { return }
        fading = true
        if syncTempo { b.sync(to: a) }
        b.seek(to: max(0, b.leadIn - 0.02))
        b.play()
        if let u = b.url, let i = playlist.firstIndex(of: u) { nextIndex = i + 1 }
        status = "Mix: \(a.title) → \(b.title)"
        let target: Double = b === deckA ? -1 : 1
        let startX = crossfader
        let steps = max(1, Int(crossfadeSeconds * 20))
        var k = 0
        Timer.scheduledTimer(withTimeInterval: crossfadeSeconds / Double(steps), repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            k += 1
            let f = Double(k) / Double(steps)
            // Curva morbida (smoothstep).
            let s = f * f * (3 - 2 * f)
            self.crossfader = startX + (target - startX) * s
            // Il tempo del brano in entrata torna gradualmente all'originale.
            if self.syncTempo { b.pitchPercent *= 0.985 }
            if k >= steps {
                t.invalidate()
                a.unload()
                if self.syncTempo { b.pitchPercent = 0 }
                self.fading = false
                self.status = self.automix ? "Automix attivo" : "Pronto"
            }
        }
    }

    private func deckEnded(_ d: Deck?) {
        guard let d = d, automix, !fading else { return }
        let next = other(d)
        if !next.isPlaying, next.url != nil, !next.loading { startTransition(from: d, to: next) }
    }
}
