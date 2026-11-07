import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct KaraokeView: View {
    @ObservedObject var player: KaraokePlayer
    @ObservedObject var library: Library
    @ObservedObject var mic: MicEngine
    @ObservedObject var external = ExternalDisplay.shared
    @ObservedObject var settings = AppSettings.shared
    @State private var showEditor = false
    @State private var showMixer = true
    @State private var diagnostics: String?
    @State private var exporting: Double?

    private func exportMP3() {
        let p = NSSavePanel()
        let t = (player.item?.title ?? "Base") + (player.transpose != 0 ? " (\(player.transpose > 0 ? "+" : "")\(player.transpose))" : "")
        p.nameFieldStringValue = t + ".mp3"
        p.directoryURL = AppPaths.exports
        guard p.runModal() == .OK, let u = p.url else { return }
        let formats: [String: ExportFormat] = ["wav": .wav, "m4a": .m4a]
        let format: ExportFormat = formats[u.pathExtension.lowercased()] ?? .mp3
        let dest = format == .mp3 && u.pathExtension.lowercased() != "mp3" ? u.appendingPathExtension("mp3") : u
        exporting = 0
        player.status = "Creo l'MP3 con le tue modifiche…"
        player.exportCurrentMIDI(to: dest, format: format, mastering: .pro, progress: { exporting = $0 }) { r in
            exporting = nil
            switch r {
            case .success(let url):
                player.status = "Salvato \(url.lastPathComponent) (con testo .lrc accanto)"
                library.addFiles([url])
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let e):
                player.status = "MP3 non creato: \(e.localizedDescription)"
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 12) {
                LyricsStageView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
                    .frame(minHeight: 180)
                TransportPanel(player: player)
                controls
                HStack(alignment: .top) {
                    Text(player.status).font(.caption).foregroundColor(Theme.soft)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let it = player.item {
                        Button(action: { diagnostics = LyricsDiagnostics.report(for: it.url) }) {
                            Label("Diagnostica testo", systemImage: "stethoscope")
                        }.buttonStyle(NeonButtonStyle(prominent: false)).font(.caption)
                    }
                }
            }
            if showMixer {
                ScrollView {
                    VStack(spacing: 12) {
                        if player.kind == .midi { MixerPanel(player: player) }
                        MicPanel(mic: mic)
                        SetlistPanel(player: player, library: library)
                    }
                }
                .frame(width: 290)
            }
        }
        .sheet(isPresented: $showEditor) { LyricsEditorView(player: player) }
        .sheet(isPresented: Binding(get: { diagnostics != nil }, set: { if !$0 { diagnostics = nil } })) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Diagnostica testo").font(.system(size: 18, weight: .heavy)).foregroundStyle(Theme.gradient)
                Text("Copia questo testo e incollalo nella chat: mostra cosa contiene il file.").font(.caption).foregroundColor(Theme.soft)
                ScrollView {
                    Text(diagnostics ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Copia") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics ?? "", forType: .string)
                    }.buttonStyle(NeonButtonStyle())
                    Spacer()
                    Button("Chiudi") { diagnostics = nil }.buttonStyle(NeonButtonStyle(prominent: false))
                }
            }
            .padding(18).frame(width: 720, height: 480).background(Theme.bg)
        }
    }

    private var controls: some View {
        Panel {
            ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("TONO").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.soft)
                    HStack {
                        Button("−") { player.transpose = max(-12, player.transpose - 1) }.buttonStyle(NeonButtonStyle(prominent: false))
                        Text(player.transpose > 0 ? "+\(player.transpose)" : "\(player.transpose)")
                            .font(.system(size: 18, weight: .bold, design: .rounded)).frame(width: 40).foregroundColor(Theme.cyan)
                        Button("+") { player.transpose = min(12, player.transpose + 1) }.buttonStyle(NeonButtonStyle(prominent: false))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("TEMPO \(Int((player.tempo * 100).rounded()))%").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.soft)
                    HStack {
                        Slider(value: $player.tempo, in: 0.6...1.4, step: 0.01).frame(width: 150).accentColor(Theme.cyan)
                        Button("100%") { player.tempo = 1 }.buttonStyle(NeonButtonStyle(prominent: false))
                    }
                }
                if player.kind == .midi && player.melodyChannel != nil {
                    Toggle(isOn: Binding(get: { !player.melodyMuted }, set: { _ in player.toggleMelody() })) {
                        Text("Melodia guida").font(.system(size: 12, weight: .semibold))
                    }.toggleStyle(.switch)
                }
                Spacer()
                SoundPickerMenu(player: player)
                if player.kind == .midi {
                    Button(action: exportMP3) {
                        Label(exporting == nil ? "Crea MP3" : "MP3 \(Int((exporting ?? 0) * 100))%", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(NeonButtonStyle(prominent: false)).disabled(exporting != nil)
                    .help("Salva la base così come la senti: suoni, tono, tempo, tracce spente e volumi")
                }
                Toggle("Accordi", isOn: $settings.showChords).toggleStyle(.switch)
                Button(action: { showEditor = true }) { Label("Testo e accordi", systemImage: "text.badge.plus") }
                    .buttonStyle(NeonButtonStyle(prominent: false)).disabled(player.item == nil || settings.showLock)
                Button(action: { external.toggle(player: player) }) {
                    Label(external.isOpen ? "Chiudi schermo" : "Schermo esterno", systemImage: "tv")
                }.buttonStyle(NeonButtonStyle(prominent: external.isOpen))
                Button(action: { withAnimation { showMixer.toggle() } }) { Image(systemName: "sidebar.right") }.buttonStyle(NeonButtonStyle(prominent: false))
            } }
        }
    }
}

struct TransportPanel: View {
    @ObservedObject var player: KaraokePlayer
    @ObservedObject var clock: PlaybackClock
    @State private var scrub: Double?

    init(player: KaraokePlayer) {
        self.player = player
        self.clock = player.clock
    }

    var body: some View {
        Panel {
            HStack(spacing: 14) {
                Button(action: { player.seek(to: 0) }) { Image(systemName: "backward.end.fill") }.buttonStyle(NeonButtonStyle(prominent: false))
                Button(action: { player.skip(-5) }) { Image(systemName: "gobackward.5") }.buttonStyle(NeonButtonStyle(prominent: false))
                Button(action: { player.togglePlay() }) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 30)
                }
                .buttonStyle(NeonButtonStyle())
                Button(action: { player.stop() }) { Image(systemName: "stop.fill") }.buttonStyle(NeonButtonStyle(prominent: false))
                Button(action: { player.skip(5) }) { Image(systemName: "goforward.5") }.buttonStyle(NeonButtonStyle(prominent: false))
                Button(action: { player.playNextNow() }) { Image(systemName: "forward.end.fill") }.buttonStyle(NeonButtonStyle(prominent: false)).help("Brano successivo della scaletta")

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.item.map { $0.artist.isEmpty ? $0.title : "\($0.artist) – \($0.title)" } ?? "Nessun brano")
                        .font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.ink).lineLimit(1)
                    HStack(spacing: 10) {
                        if let k = player.kind { Label(k == .midi ? "MIDI" : (k == .video ? "Video" : "Audio"), systemImage: k.icon) }
                        if let b = player.bpm { Text("\(Int((b * player.tempo).rounded())) BPM") }
                        if !player.keyName.isEmpty { Text(player.keyName) }
                        if player.analyzing { ProgressView().scaleEffect(0.5).frame(width: 14, height: 14); Text("analizzo accordi…") }
                    }.font(.caption).foregroundColor(Theme.soft)
                }
                Spacer()
            }
            HStack {
                Text(formatTime(scrub ?? player.position)).monospacedDigit().foregroundColor(Theme.soft)
                Slider(value: Binding(get: { scrub ?? player.position }, set: { scrub = $0 }),
                       in: 0...max(1, player.duration),
                       onEditingChanged: { editing in if !editing, let s = scrub { player.seek(to: s); scrub = nil } })
                    .accentColor(Theme.violet)
                Text("-" + formatTime(player.duration - (scrub ?? player.position))).monospacedDigit().foregroundColor(Theme.soft)
            }.font(.system(size: 12))
            if !player.sections.isEmpty && player.duration > 0 {
                SectionStrip(sections: player.sections, duration: player.duration, position: player.position) { player.seek(to: $0) }
                    .frame(height: 22)
            }
        }
    }

}

/// Barra della struttura (INTRO/VERSE/CHORUS…), cliccabile per saltare.
struct SectionStrip: View {
    var sections: [SongSection]
    var duration: Double
    var position: Double
    var onTap: (Double) -> Void

    static func color(_ k: SectionKind) -> Color {
        switch k {
        case .intro, .outro: return Theme.line
        case .verse: return Theme.blue
        case .preChorus: return Theme.violet.opacity(0.7)
        case .chorus: return Theme.magenta
        case .bridge: return Theme.cyan.opacity(0.8)
        case .instrumental: return Theme.violet
        }
    }

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                ForEach(sections) { s in
                    let x = g.size.width * CGFloat(s.start / duration)
                    let w = max(2, g.size.width * CGFloat((s.end - s.start) / duration) - 2)
                    Button(action: { onTap(s.start) }) {
                        Text(s.title).font(.system(size: 9, weight: .bold)).lineLimit(1).foregroundColor(.white)
                            .frame(width: w, height: g.size.height)
                            .background(RoundedRectangle(cornerRadius: 4).fill(SectionStrip.color(s.kind)))
                    }.buttonStyle(.plain).offset(x: x)
                }
                Rectangle().fill(Color.white).frame(width: 2, height: g.size.height)
                    .offset(x: g.size.width * CGFloat(min(1, position / max(1, duration))))
            }
        }
    }
}

struct MixerPanel: View {
    @ObservedObject var player: KaraokePlayer
    var body: some View {
        Panel(title: "Mixer tracce", icon: "slider.vertical.3") {
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(player.channels) { c in
                        HStack(spacing: 6) {
                            Text("\(c.channel + 1)").font(.system(size: 10, weight: .bold)).frame(width: 18).foregroundColor(Theme.soft)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.name).font(.system(size: 11, weight: c.isMelody ? .bold : .regular)).lineLimit(1)
                                    .foregroundColor(c.isMelody ? Theme.magenta : Theme.ink)
                                Slider(value: Binding(get: { c.gain }, set: { player.setGain(c.channel, $0) }), in: 0...1.27)
                                    .controlSize(.mini).accentColor(Theme.cyan)
                            }
                            Button("M") { player.setMuted(c.channel, !c.muted) }
                                .buttonStyle(MiniToggleStyle(on: c.muted, color: .red))
                            Button("S") { player.setSolo(c.channel, !c.solo) }
                                .buttonStyle(MiniToggleStyle(on: c.solo, color: Theme.warn))
                        }
                    }
                }
            }.frame(maxHeight: 260)
        }
    }
}

struct MiniToggleStyle: ButtonStyle {
    var on: Bool
    var color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .heavy)).frame(width: 20, height: 18)
            .foregroundColor(on ? .black : Theme.soft)
            .background(RoundedRectangle(cornerRadius: 4).fill(on ? color : Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.line))
    }
}

struct MicPanel: View {
    @ObservedObject var mic: MicEngine
    var body: some View {
        Panel(title: "Microfono", icon: "mic.fill") {
            Toggle("Microfono con effetti", isOn: $mic.enabled).toggleStyle(.switch)
            if mic.enabled {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.bg2)
                        Capsule().fill(Theme.gradient).frame(width: g.size.width * CGFloat(min(1, mic.level * 1.5)))
                    }
                }.frame(height: 6)
                labeled("Volume", $mic.volume, 0...1.5)
                labeled("Riverbero", $mic.reverb, 0...80)
                labeled("Eco", $mic.echo, 0...60)
                labeled("Tempo eco", $mic.echoTime, 0.08...0.6)
                Text("Usa le cuffie o tieni il microfono lontano dalle casse per evitare il fischio.")
                    .font(.system(size: 10)).foregroundColor(Theme.soft)
            }
            if let e = mic.error { Text(e).font(.caption).foregroundColor(Theme.warn) }
        }
    }
    private func labeled(_ t: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        HStack { Text(t).font(.system(size: 11)).frame(width: 70, alignment: .leading); Slider(value: v, in: r).controlSize(.small).accentColor(Theme.violet) }
    }
}

struct SetlistPanel: View {
    @ObservedObject var player: KaraokePlayer
    @ObservedObject var library: Library
    var body: some View {
        Panel(title: "Scaletta della serata", icon: "list.number") {
            if library.setlist.isEmpty {
                Text("Trascina qui i brani o usa \"Aggiungi alla scaletta\" dall'archivio.")
                    .font(.caption).foregroundColor(Theme.soft).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                List {
                    ForEach(library.setlist, id: \.self) { it in
                        HStack {
                            Image(systemName: it.kind.icon).foregroundColor(it == player.item ? Theme.magenta : Theme.cyan)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(it.title).font(.system(size: 12, weight: it == player.item ? .bold : .regular)).lineLimit(1)
                                if !it.artist.isEmpty { Text(it.artist).font(.system(size: 10)).foregroundColor(Theme.soft).lineLimit(1) }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.load(it, autoplay: true) }
                        .contextMenu {
                            Button("Suona ora") { player.load(it, autoplay: true) }
                            Button("Togli dalla scaletta") { library.setlist.removeAll { $0 == it } }
                        }
                    }
                    .onMove { library.setlist.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { library.setlist.remove(atOffsets: $0) }
                }
                .frame(minHeight: 120)
            }
            HStack {
                Toggle("Avanti automatico", isOn: Binding(get: { AppSettings.shared.autoAdvance }, set: { AppSettings.shared.autoAdvance = $0 }))
                    .toggleStyle(.switch).font(.system(size: 11))
                Spacer()
                Button("Svuota") { library.setlist.removeAll() }.buttonStyle(NeonButtonStyle(prominent: false)).disabled(library.setlist.isEmpty)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let u = url, SongKind.of(u) != nil else { return }
                    DispatchQueue.main.async { library.setlist.append(LibraryItem(url: u)) }
                }
            }
            return true
        }
    }
}
