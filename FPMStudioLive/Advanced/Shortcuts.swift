import Foundation
import AppKit
import SwiftUI

/// Profilo di scorciatoie da tastiera rimappabile (sezione N), valido anche per i pedali
/// Bluetooth "volta-pagina" che si presentano come tastiera (PagGiù/PagSu/frecce).
final class ShortcutManager: ObservableObject {
    enum Command: String, CaseIterable, Identifiable, Codable {
        case playPause, fromStart, stop, next, fadeOut, transposeUp, transposeDown, tempoUp, tempoDown, resetTempo
        case melodyToggle, melodyOnly, drumsOnly, bassDrums, allChannels, resetChannels
        case addMarker, pageForward, pageBack, fullscreen, metronome
        var id: String { rawValue }
        var label: String {
            switch self {
            case .playPause: return "Play / Pausa"
            case .fromStart: return "Dall'inizio"
            case .stop: return "Stop"
            case .next: return "Avvia brano prenotato (successivo)"
            case .fadeOut: return "Fade out"
            case .transposeUp: return "Tono +1"
            case .transposeDown: return "Tono −1"
            case .tempoUp: return "Tempo +"
            case .tempoDown: return "Tempo −"
            case .resetTempo: return "Reset tempo"
            case .melodyToggle: return "Melodia on/off"
            case .melodyOnly: return "Solo melodia"
            case .drumsOnly: return "Solo batteria"
            case .bassDrums: return "Basso + batteria"
            case .allChannels: return "Tutti i canali"
            case .resetChannels: return "Reset canali"
            case .addMarker: return "Marker veloce (quick save)"
            case .pageForward: return "Leggio: pagina avanti"
            case .pageBack: return "Leggio: pagina indietro"
            case .fullscreen: return "Schermo esterno"
            case .metronome: return "Metronomo on/off"
            }
        }
        /// Profilo predefinito ispirato alle scorciatoie live più diffuse.
        var defaultKey: String {
            switch self {
            case .playPause: return "space"
            case .fromStart: return "o"
            case .stop: return "end"
            case .next: return "return"
            case .fadeOut: return "q"
            case .transposeUp: return "+"
            case .transposeDown: return "-"
            case .tempoUp: return "pageup"
            case .tempoDown: return "pagedown"
            case .resetTempo: return "t"
            case .melodyToggle: return "m"
            case .melodyOnly: return "u"
            case .drumsOnly: return "d"
            case .bassDrums: return "b"
            case .allChannels: return "a"
            case .resetChannels: return "n"
            case .addMarker: return "k"
            case .pageForward: return "right"
            case .pageBack: return "left"
            case .fullscreen: return "z"
            case .metronome: return "c"
            }
        }
    }

    @Published var bindings: [Command: String] { didSet { save() } }
    @Published var enabled = true
    private var monitor: Any?
    weak var player: KaraokePlayer?

    init() {
        var b: [Command: String] = [:]
        let saved = UserDefaults.standard.dictionary(forKey: "shortcuts") as? [String: String] ?? [:]
        for c in Command.allCases { b[c] = saved[c.rawValue] ?? c.defaultKey }
        bindings = b
    }

    private func save() {
        var d: [String: String] = [:]
        for (k, v) in bindings { d[k.rawValue] = v }
        UserDefaults.standard.set(d, forKey: "shortcuts")
    }

    func resetDefaults() { for c in Command.allCases { bindings[c] = c.defaultKey } }

    /// Tasti assegnati a più comandi.
    var conflicts: Set<String> {
        var seen: [String: Int] = [:]
        for v in bindings.values where !v.isEmpty { seen[v, default: 0] += 1 }
        return Set(seen.filter { $0.value > 1 }.keys)
    }

    static func keyName(_ e: NSEvent) -> String {
        switch e.keyCode {
        case 49: return "space"
        case 36, 76: return "return"
        case 53: return "esc"
        case 116: return "pageup"
        case 121: return "pagedown"
        case 119: return "end"
        case 115: return "home"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 51: return "delete"
        case 114: return "ins"
        case 69: return "+"
        case 78: return "-"
        default:
            if let f = e.specialKey, let i = [NSEvent.SpecialKey.f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12].firstIndex(of: f) { return "f\(i + 1)" }
            return (e.charactersIgnoringModifiers ?? "").lowercased()
        }
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.enabled, let p = self.player else { return e }
            // Mai mentre si scrive in un campo di testo, né con ⌘/⌃/⌥.
            if e.modifierFlags.intersection([.command, .control, .option]).isEmpty == false { return e }
            if NSApp.keyWindow?.firstResponder is NSTextView { return e }
            if NSApp.keyWindow?.attachedSheet != nil || NSApp.modalWindow != nil { return e }
            let key = ShortcutManager.keyName(e)
            guard let cmd = self.bindings.first(where: { $0.value == key })?.key else { return e }
            self.perform(cmd, on: p)
            return nil
        }
    }

    func perform(_ c: Command, on p: KaraokePlayer) {
        switch c {
        case .playPause: p.togglePlay()
        case .fromStart: p.seek(to: 0); if !p.isPlaying { p.play() }
        case .stop: p.stop()
        case .next: p.playNextNow()
        case .fadeOut: p.fadeOut()
        case .transposeUp: p.transpose = min(12, p.transpose + 1)
        case .transposeDown: p.transpose = max(-12, p.transpose - 1)
        case .tempoUp: p.tempoStep(0.02)
        case .tempoDown: p.tempoStep(-0.02)
        case .resetTempo: p.resetTempo()
        case .melodyToggle: p.toggleMelody()
        case .melodyOnly: p.applyChannelMode(.melodyOnly)
        case .drumsOnly: p.applyChannelMode(.drumsOnly)
        case .bassDrums: p.applyChannelMode(.bassAndDrums)
        case .allChannels: p.applyChannelMode(.all)
        case .resetChannels: p.resetChannels()
        case .addMarker: p.addMarker()
        case .pageForward: p.pdfPage += 1
        case .pageBack: p.pdfPage = max(1, p.pdfPage - 1)
        case .fullscreen: ExternalDisplay.shared.toggle(player: p)
        case .metronome: p.metronome.toggle()
        }
    }
}

struct ShortcutsEditor: View {
    @ObservedObject var shortcuts: ShortcutManager
    @State private var capturing: ShortcutManager.Command?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Scorciatoie attive", isOn: $shortcuts.enabled).toggleStyle(.switch)
                Spacer()
                Button("Profilo predefinito") { shortcuts.resetDefaults() }.buttonStyle(NeonButtonStyle(prominent: false))
            }
            Text("Clicca un tasto e premi il nuovo tasto (anche il pedale Bluetooth). I conflitti sono in arancione. Le scorciatoie non agiscono mentre scrivi in un campo di testo.")
                .font(.caption).foregroundColor(Theme.soft)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(ShortcutManager.Command.allCases) { c in
                        let key = shortcuts.bindings[c] ?? ""
                        HStack {
                            Text(c.label).font(.system(size: 12))
                            Spacer()
                            Button(capturing == c ? "premi un tasto…" : key.uppercased()) { startCapture(c) }
                                .buttonStyle(NeonButtonStyle(prominent: capturing == c))
                                .foregroundColor(shortcuts.conflicts.contains(key) ? Theme.warn : .white)
                            Button("×") { shortcuts.bindings[c] = "" }.buttonStyle(.plain).foregroundColor(Theme.soft)
                        }
                    }
                }
            }
        }
        .onDisappear { stopCapture() }
    }

    private func startCapture(_ c: ShortcutManager.Command) {
        stopCapture()
        capturing = c
        shortcuts.enabled = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            shortcuts.bindings[c] = ShortcutManager.keyName(e)
            stopCapture()
            return nil
        }
    }

    private func stopCapture() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if capturing != nil { shortcuts.enabled = true }
        capturing = nil
    }
}
