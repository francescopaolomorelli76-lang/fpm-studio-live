import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Editor di testo e accordi per basi MIDI, MP3 e video (stile Win Live):
/// 1. scrivi o incolla il testo (accordi tra [ ], sillabe separate da /);
/// 2. SINCRONIZZA: avvia il brano e premi SPAZIO su ogni sillaba (← annulla, ↵ salta riga);
/// 3. aggiusta l'anticipo/ritardo e salva.
struct LyricsEditorView: View {
    @ObservedObject var player: KaraokePlayer
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.presentationMode) var presentationMode
    @State private var text = ""
    @State private var syncing = false
    @State private var syncCursor = 0          // indice nella lista piatta delle sillabe
    @State private var monitor: Any?
    @State private var message = ""
    @State private var chordsFromText = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Testo e accordi").font(.system(size: 20, weight: .heavy)).foregroundStyle(Theme.gradient)
                Text(player.item?.title ?? "").foregroundColor(Theme.soft)
                Spacer()
                Button("Chiudi") { stopSync(); presentationMode.wrappedValue.dismiss() }.buttonStyle(NeonButtonStyle(prominent: false))
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Una riga per verso, riga vuota tra le strofe. Accordi tra parentesi: [Lam]Nel blu di[Re]pinto. Sillabe con /: can/ta/re.")
                        .font(.caption).foregroundColor(Theme.soft)
                    TextEditor(text: $text)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                        .disabled(syncing)
                    HStack {
                        Button("Applica testo") { apply() }.buttonStyle(NeonButtonStyle())
                        Button("Importa .lrc/.txt") { importText() }.buttonStyle(NeonButtonStyle(prominent: false))
                        Button("Esporta .lrc") { exportLRC() }.buttonStyle(NeonButtonStyle(prominent: false))
                        if player.kind == .midi {
                            Button("Accordi automatici") { autoChords() }.buttonStyle(NeonButtonStyle(prominent: false))
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Panel(title: "Sincronizzazione", icon: "metronome") {
                        Text(syncing ? "Premi SPAZIO all'inizio di ogni sillaba evidenziata.\n← torna indietro · ↵ fine riga · ESC ferma" :
                                "Il brano parte da capo: premi SPAZIO a ritmo, sillaba per sillaba.")
                            .font(.caption).foregroundColor(Theme.soft)
                        Button(syncing ? "Ferma sincronizzazione" : "Sincronizza") { syncing ? stopSync() : startSync() }
                            .buttonStyle(NeonButtonStyle(prominent: !syncing))
                            .disabled(player.lyrics.isEmpty)
                        if syncing { syncPreview }
                        HStack {
                            Text("Anticipo testo").font(.caption)
                            Slider(value: $player.lyricsOffset, in: -2...2, step: 0.05)
                            Text(String(format: "%+.2f s", player.lyricsOffset)).monospacedDigit().font(.caption)
                        }
                    }
                    Panel(title: "Struttura", icon: "rectangle.split.3x1") {
                        ForEach(Array(player.sections.enumerated()), id: \.element.id) { i, s in
                            HStack {
                                Picker("", selection: Binding(get: { s.kind }, set: { player.sections[i].kind = $0; renumber() })) {
                                    ForEach(SectionKind.allCases) { k in Text(k.label).tag(k) }
                                }.frame(width: 130)
                                Text("\(formatTime(s.start)) – \(formatTime(s.end))").font(.caption).monospacedDigit()
                                Spacer()
                                Button("Da qui") { player.sections[i].start = player.position; if i > 0 { player.sections[i - 1].end = player.position } }
                                    .font(.caption)
                            }
                        }
                        Button("Aggiungi sezione alla posizione attuale") {
                            let t = player.position
                            if let i = player.sections.firstIndex(where: { $0.start <= t && $0.end > t }) {
                                var n = player.sections[i]
                                n.start = t; n.id = UUID()
                                player.sections[i].end = t
                                player.sections.insert(n, at: i + 1)
                                renumber()
                            }
                        }.font(.caption)
                    }
                    Spacer()
                    HStack {
                        Text(message).font(.caption).foregroundColor(Theme.cyan)
                        Spacer()
                        Button("Salva") { apply(); player.saveSidecar(); message = "Salvato accanto al brano (.fpm.json)" }
                            .buttonStyle(NeonButtonStyle())
                    }
                }.frame(width: 360)
            }
        }
        .padding(18)
        .frame(minWidth: 980, minHeight: 640)
        .background(Theme.bg)
        .onAppear { text = player.lyrics.editorText(notation: settings.notation) }
        .onDisappear { stopSync() }
    }

    private var syncPreview: some View {
        let flat = player.lyrics.flat
        let cur = min(syncCursor, max(0, flat.count - 1))
        let line = flat.isEmpty ? 0 : flat[cur].line
        return VStack(alignment: .leading, spacing: 4) {
            if player.lyrics.lines.indices.contains(line) {
                HStack(spacing: 0) {
                    ForEach(Array(player.lyrics.lines[line].syllables.enumerated()), id: \.offset) { si, s in
                        Text(s.text).font(.system(size: 18, weight: .bold))
                            .foregroundColor(flat.indices.contains(cur) && flat[cur].index == si ? Theme.magenta : (s.time >= 0 ? Theme.cyan : Theme.soft))
                    }
                }
            }
            Text("\(cur)/\(flat.count) sillabe").font(.caption).foregroundColor(Theme.soft)
        }
    }

    private func apply() {
        let newLyrics = KaraokeLyrics.fromEditorText(text, keeping: player.lyrics)
        player.lyrics = newLyrics
        let manual = newLyrics.chordEvents
        if !manual.isEmpty { player.chords = manual }
        message = "Testo applicato: \(newLyrics.lines.count) righe"
    }

    private func autoChords() {
        guard let m = player.midi else { return }
        let an = ChordEngine.analyze(m, lyrics: player.lyrics)
        player.chords = ChordEngine.events(an.regions, midi: m)
        // Scrivo gli accordi nel testo, sulla sillaba più vicina.
        var lyr = player.lyrics
        for li in lyr.lines.indices { for si in lyr.lines[li].syllables.indices { lyr.lines[li].syllables[si].chord = nil } }
        for c in player.chords {
            var best: (Int, Int)?
            var bestD = 1.0
            for (li, l) in lyr.lines.enumerated() { for (si, s) in l.syllables.enumerated() where s.time >= 0 {
                let d = abs(s.time - c.time)
                if d < bestD { bestD = d; best = (li, si) }
            } }
            if let b = best { lyr.lines[b.0].syllables[b.1].chord = c.chord }
        }
        player.lyrics = lyr
        text = lyr.editorText(notation: settings.notation)
        message = "Accordi riconosciuti dal MIDI: \(player.chords.count)"
    }

    private func renumber() {
        var counters: [SectionKind: Int] = [:]
        for i in player.sections.indices {
            counters[player.sections[i].kind, default: 0] += 1
            player.sections[i].number = counters[player.sections[i].kind]!
        }
    }

    // MARK: Sincronizzazione con la tastiera

    private func startSync() {
        apply()
        guard !player.lyrics.isEmpty else { return }
        // Azzero i tempi.
        var lyr = player.lyrics
        for li in lyr.lines.indices { for si in lyr.lines[li].syllables.indices { lyr.lines[li].syllables[si].time = -1 } }
        player.lyrics = lyr
        syncCursor = 0
        syncing = true
        player.lyricsOffset = 0
        player.seek(to: 0)
        player.play()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            guard syncing else { return ev }
            switch ev.keyCode {
            case 49: stamp(); return nil                    // spazio
            case 123: undo(); return nil                    // freccia sinistra
            case 36: skipLine(); return nil                 // invio
            case 53: stopSync(); return nil                 // esc
            default: return ev
            }
        }
    }

    private func stamp() {
        let flat = player.lyrics.flat
        guard syncCursor < flat.count else { stopSync(); return }
        let f = flat[syncCursor]
        // Compenso il tempo di reazione (circa 80 ms).
        player.lyrics.lines[f.line].syllables[f.index].time = max(0, player.position - 0.08)
        syncCursor += 1
        if syncCursor >= flat.count { message = "Sincronizzazione completata"; stopSync() }
    }

    private func undo() {
        guard syncCursor > 0 else { return }
        syncCursor -= 1
        let f = player.lyrics.flat[syncCursor]
        player.lyrics.lines[f.line].syllables[f.index].time = -1
        player.seek(to: max(0, player.position - 3))
    }

    /// Distribuisce le sillabe rimanenti della riga fino all'istante attuale.
    private func skipLine() {
        let flat = player.lyrics.flat
        guard syncCursor < flat.count else { return }
        let line = flat[syncCursor].line
        let rest = flat[syncCursor...].filter { $0.line == line }
        let prevTime = syncCursor > 0 ? flat[syncCursor - 1].syllable.time : 0
        let now = player.position
        for (k, f) in rest.enumerated() {
            player.lyrics.lines[f.line].syllables[f.index].time = prevTime + (now - prevTime) * Double(k + 1) / Double(rest.count + 1)
        }
        syncCursor += rest.count
    }

    private func stopSync() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if syncing { player.pause() }
        syncing = false
        // Le sillabe non battute prendono un tempo interpolato.
        var lyr = player.lyrics
        var lastT = 0.0
        for li in lyr.lines.indices {
            for si in lyr.lines[li].syllables.indices {
                if lyr.lines[li].syllables[si].time < 0 { lyr.lines[li].syllables[si].time = -1 } else { lastT = lyr.lines[li].syllables[si].time }
            }
        }
        _ = lastT
        player.lyrics = lyr
        text = lyr.editorText(notation: settings.notation)
    }

    private func importText() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText, .text]
        guard p.runModal() == .OK, let u = p.url, let s = try? String(contentsOf: u) else { return }
        if u.pathExtension.lowercased() == "lrc" {
            player.lyrics = KaraokeLyrics.fromLRC(s)
            text = player.lyrics.editorText(notation: settings.notation)
            message = "LRC importato (tempi per riga)"
        } else {
            text = s
            apply()
        }
    }

    private func exportLRC() {
        let p = NSSavePanel()
        p.nameFieldStringValue = (player.item?.title ?? "testo") + ".lrc"
        guard p.runModal() == .OK, let u = p.url else { return }
        try? player.lyrics.lrc().write(to: u, atomically: true, encoding: .utf8)
        message = "Esportato \(u.lastPathComponent)"
    }
}
