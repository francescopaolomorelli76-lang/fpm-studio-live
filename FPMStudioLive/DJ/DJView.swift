import SwiftUI
import UniformTypeIdentifiers

struct DJView: View {
    @ObservedObject var dj: DJController
    @ObservedObject var library: Library
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                DeckView(deck: dj.deckA, other: dj.deckB, accent: Theme.cyan, dj: dj)
                centerColumn.frame(width: 200)
                DeckView(deck: dj.deckB, other: dj.deckA, accent: Theme.magenta, dj: dj)
            }
            playlist
        }
        .onAppear {
            dj.soundBank = { AppSettings.shared.soundFontPath }
            dj.crossfadeSeconds = settings.crossfadeSeconds
        }
    }

    private var centerColumn: some View {
        Panel(title: "Mix", icon: "dial.medium") {
            VStack(spacing: 14) {
                Button(action: { dj.mixNow() }) {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 30))
                        Text("MIX").font(.system(size: 16, weight: .heavy))
                        Text("passa al brano in attesa").font(.system(size: 9))
                    }.frame(maxWidth: .infinity, minHeight: 86)
                }.buttonStyle(NeonButtonStyle())
                .help("Miscela il brano che suona con quello in attesa sull'altro deck")
                Button(action: { dj.automix.toggle() }) {
                    Label(dj.automix ? "AUTOMIX ON" : "AUTOMIX", systemImage: dj.automix ? "wand.and.stars" : "wand.and.rays")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(NeonButtonStyle(prominent: dj.automix))
                .help("A fine brano mixa da solo con il successivo della playlist")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dissolvenza \(Int(dj.crossfadeSeconds)) s").font(.caption).foregroundColor(Theme.soft)
                    Slider(value: Binding(get: { dj.crossfadeSeconds }, set: { dj.crossfadeSeconds = $0; settings.crossfadeSeconds = $0 }), in: 2...20, step: 1)
                }
                Toggle("Allinea BPM e battuta", isOn: $dj.syncTempo).toggleStyle(.switch).font(.caption)
                Text(dj.status).font(.caption).foregroundColor(Theme.cyan).multilineTextAlignment(.center).frame(minHeight: 30)
                Spacer(minLength: 0)
                Text("CROSSFADER").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.soft)
                HStack {
                    Text("A").foregroundColor(Theme.cyan).bold()
                    Slider(value: $dj.crossfader, in: -1...1).accentColor(Theme.violet)
                    Text("B").foregroundColor(Theme.magenta).bold()
                }
            }
        }
    }

    private var playlist: some View {
        Panel(title: "Playlist automix (MP3 e basi MIDI)", icon: "music.note.list") {
            HStack {
                Text("Trascina qui i brani dall'archivio o dal Finder. Doppio clic: carica nel deck libero.").font(.caption).foregroundColor(Theme.soft)
                Spacer()
                Button("Aggiungi scaletta karaoke") { dj.playlist += library.setlist.map { $0.url } }.buttonStyle(NeonButtonStyle(prominent: false))
                Button("Svuota") { dj.playlist.removeAll() }.buttonStyle(NeonButtonStyle(prominent: false))
            }
            List {
                ForEach(Array(dj.playlist.enumerated()), id: \.offset) { i, u in
                    HStack {
                        Text("\(i + 1)").font(.caption).foregroundColor(Theme.soft).frame(width: 24)
                        Image(systemName: SongKind.of(u)?.icon ?? "music.note").foregroundColor(i == dj.nextIndex ? Theme.magenta : Theme.cyan)
                        Text(u.deletingPathExtension().lastPathComponent).fontWeight(i == dj.nextIndex ? .bold : .regular)
                        if i == dj.nextIndex { Text("PROSSIMO").font(.system(size: 9, weight: .heavy)).foregroundColor(Theme.magenta) }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        let target = dj.deckA.isPlaying ? dj.deckB : dj.deckA
                        dj.load(u, into: target)
                    }
                    .contextMenu {
                        Button("Carica nel deck A") { dj.load(u, into: dj.deckA) }
                        Button("Carica nel deck B") { dj.load(u, into: dj.deckB) }
                        Button("Suona dopo") { dj.playlist.remove(at: i); dj.playlist.insert(u, at: min(dj.nextIndex, dj.playlist.count)) }
                        Button("Rimuovi") { dj.playlist.remove(at: i) }
                    }
                }
                .onMove { dj.playlist.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 140)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let u = url, SongKind.of(u) != nil, SongKind.of(u) != .video else { return }
                        DispatchQueue.main.async { dj.playlist.append(u) }
                    }
                }
                return true
            }
        }
    }
}

struct DeckView: View {
    @ObservedObject var deck: Deck
    var other: Deck
    var accent: Color
    var dj: DJController

    var body: some View {
        Panel(title: "Deck \(deck.id)", icon: "opticaldisc") {
            Text(deck.title).font(.system(size: 15, weight: .bold)).lineLimit(1).foregroundColor(Theme.ink)
            HStack {
                Text(deck.effectiveBPM.map { String(format: "%.1f BPM", $0) } ?? "— BPM").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(accent)
                Spacer()
                Text(formatTime(deck.position)).monospacedDigit()
                Text("-" + formatTime(max(0, deck.duration - deck.position))).monospacedDigit().foregroundColor(Theme.soft)
            }.font(.system(size: 12))
            WaveformView(samples: deck.waveform, progress: deck.duration > 0 ? deck.position / deck.duration : 0,
                         cue: deck.duration > 0 ? deck.cuePoint / deck.duration : 0, accent: accent) { f in deck.seek(to: f * deck.duration) }
                .frame(height: 70)
                .overlay(Group { if deck.loading { ProgressView(value: deck.loadProgress).padding() } })
            HStack(spacing: 8) {
                Button(action: { deck.cue() }) { Text("CUE").frame(width: 40) }.buttonStyle(NeonButtonStyle(prominent: false))
                Button(action: { deck.togglePlay() }) { Image(systemName: deck.isPlaying ? "pause.fill" : "play.fill").frame(width: 40) }
                    .buttonStyle(NeonButtonStyle())
                Button(action: { deck.sync(to: other) }) { Text("SYNC") }.buttonStyle(NeonButtonStyle(prominent: false))
                Toggle("Key lock", isOn: $deck.keyLock).toggleStyle(.switch).font(.caption)
            }
            HStack(alignment: .bottom, spacing: 16) {
                knob("BASSI", $deck.eqLow)
                knob("MEDI", $deck.eqMid)
                knob("ALTI", $deck.eqHigh)
                VStack {
                    Text("VOL").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.soft)
                    Slider(value: $deck.volume, in: 0...1.2).frame(width: 90).accentColor(accent)
                }
            }
            HStack {
                Text("Pitch \(String(format: "%+.1f%%", deck.pitchPercent))").font(.caption).frame(width: 80, alignment: .leading)
                Slider(value: $deck.pitchPercent, in: -16...16).accentColor(accent)
                Button("0") { deck.pitchPercent = 0 }.buttonStyle(NeonButtonStyle(prominent: false))
            }
            if let e = deck.error { Text(e).font(.caption).foregroundColor(Theme.warn) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                guard let u = url, SongKind.of(u) != nil else { return }
                DispatchQueue.main.async { dj.load(u, into: deck) }
            }
            return true
        }
    }

    private func knob(_ label: String, _ v: Binding<Double>) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 9, weight: .bold)).foregroundColor(Theme.soft)
            Slider(value: v, in: -24...6).frame(width: 70).controlSize(.small).accentColor(accent)
            Text(String(format: "%+.0f dB", v.wrappedValue)).font(.system(size: 9)).foregroundColor(Theme.soft)
        }
    }
}

struct WaveformView: View {
    var samples: [Float]
    var progress: Double
    var cue: Double
    var accent: Color
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8).fill(Theme.bg2)
                Canvas { ctx, size in
                    guard !samples.isEmpty else { return }
                    let mx = max(0.001, samples.max() ?? 1)
                    let w = size.width / CGFloat(samples.count)
                    for (i, s) in samples.enumerated() {
                        let h = CGFloat(s / mx) * size.height * 0.9
                        let x = CGFloat(i) * w
                        let played = Double(i) / Double(samples.count) < progress
                        ctx.fill(Path(CGRect(x: x, y: (size.height - h) / 2, width: max(1, w - 0.5), height: h)),
                                 with: .color(played ? accent.opacity(0.45) : accent))
                    }
                }
                Rectangle().fill(Theme.warn).frame(width: 2).offset(x: g.size.width * CGFloat(cue))
                Rectangle().fill(Color.white).frame(width: 2).offset(x: g.size.width * CGFloat(min(1, progress)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in onSeek(max(0, min(1, Double(v.location.x / g.size.width)))) })
        }
    }
}
