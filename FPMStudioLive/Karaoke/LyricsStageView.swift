import SwiftUI
import AVKit
import AppKit

/// Testo karaoke a schermo: riga attiva colorata sillaba per sillaba, riga successiva,
/// accordi sopra le sillabe, conto alla rovescia prima dell'attacco, titolo tra un brano e l'altro.
struct LyricsStageView: View {
    @ObservedObject var player: KaraokePlayer
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var settings = AppSettings.shared
    var fontScale: CGFloat = 1
    var showVideo = true

    init(player: KaraokePlayer, fontScale: CGFloat = 1, showVideo: Bool = true) {
        self.player = player
        self.clock = player.clock
        self.fontScale = fontScale
        self.showVideo = showVideo
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.background
                if showVideo, let vp = player.videoPlayer {
                    VideoLayerView(player: vp).opacity(0.85)
                    LinearGradient(gradient: Gradient(colors: [.clear, Color.black.opacity(0.75)]), startPoint: .center, endPoint: .bottom)
                } else {
                    Image("Logo").resizable().scaledToFit().opacity(0.07).padding(geo.size.height * 0.08)
                }
                content(size: geo.size)
                if let b = player.banner, !b.isEmpty {
                    VStack {
                        Spacer()
                        Text(b).font(.system(size: max(18, geo.size.width / 36), weight: .heavy)).foregroundColor(.white)
                            .padding(.vertical, 10).frame(maxWidth: .infinity)
                            .background(Theme.gradient)
                    }
                }
            }
        }
        .clipped()
    }

    @ViewBuilder
    private func content(size: CGSize) -> some View {
        let t = player.lyricsTime
        let fs = CGFloat(settings.lyricsFontSize) * fontScale * max(0.5, min(2.2, size.width / 1100))
        if player.item == nil {
            VStack(spacing: 16) {
                Image("Logo").resizable().scaledToFit().frame(width: min(size.width, size.height) * 0.38)
                Text("FPM Studio Live").font(.system(size: fs * 0.8, weight: .heavy)).foregroundStyle(Theme.gradient)
            }
        } else if let countdown = player.countdownToNext, let next = player.nextUpTitle {
            VStack(spacing: 18) {
                Text("PROSSIMO BRANO").font(.system(size: fs * 0.35, weight: .bold)).tracking(4).foregroundColor(Theme.soft)
                Text(next).font(.system(size: fs, weight: .heavy)).foregroundStyle(Theme.gradient).multilineTextAlignment(.center)
                Text("\(Int(countdown.rounded(.up)))").font(.system(size: fs * 0.8, weight: .bold, design: .rounded)).foregroundColor(Theme.ink)
            }.padding()
        } else if player.lyrics.isEmpty {
            VStack(spacing: 10) {
                Text(player.lyrics.title ?? player.item?.title ?? "").font(.system(size: fs * 0.9, weight: .heavy)).foregroundStyle(Theme.gradient)
                if let a = player.item?.artist, !a.isEmpty { Text(a).font(.system(size: fs * 0.45)).foregroundColor(Theme.soft) }
                if settings.showChords, let ci = player.currentChordIndex(at: t) {
                    Text(player.displayChord(player.chords[ci].chord)).font(.system(size: fs * 1.2, weight: .bold, design: .rounded)).foregroundColor(Theme.cyan)
                        .padding(.top, 30)
                }
            }.multilineTextAlignment(.center).padding()
        } else {
            let li = player.lyrics.lineIndex(at: t)
            let firstStart = player.lyrics.lines.first?.startTime ?? 0
            VStack(spacing: fs * 0.35) {
                Spacer()
                if li == nil {
                    // Prima dell'attacco: titolo e conto alla rovescia.
                    Text(player.lyrics.title ?? player.item?.title ?? "").font(.system(size: fs * 0.8, weight: .heavy)).foregroundStyle(Theme.gradient)
                    if let a = player.item?.artist, !a.isEmpty { Text(a).font(.system(size: fs * 0.42)).foregroundColor(Theme.soft) }
                    countdownDots(firstStart - t, fs: fs)
                }
                let current = li ?? -1
                ForEach(Array(visibleLines(current: current).enumerated()), id: \.offset) { _, idx in
                    LyricLineView(line: player.lyrics.lines[idx], active: idx == current, time: t,
                                  progress: lineProgress(idx, current: current, t: t),
                                  chords: settings.showChords ? chordsFor(line: idx) : [], fontSize: idx == current ? fs : fs * 0.78)
                        .opacity(idx == current ? 1 : 0.55)
                }
                Spacer()
                HStack {
                    if let s = player.currentSection {
                        Text(s.title).font(.system(size: fs * 0.22, weight: .bold)).tracking(2)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().stroke(Theme.violet, lineWidth: 1)).foregroundColor(Theme.soft)
                    }
                    Spacer()
                    if let ci = player.currentChordIndex(at: t), settings.showChords {
                        Text(player.displayChord(player.chords[ci].chord)).font(.system(size: fs * 0.4, weight: .bold, design: .rounded)).foregroundColor(Theme.cyan)
                        if ci + 1 < player.chords.count {
                            Text("→ " + player.displayChord(player.chords[ci + 1].chord)).font(.system(size: fs * 0.28, weight: .semibold)).foregroundColor(Theme.soft)
                        }
                    }
                }.padding(.horizontal, 24).padding(.bottom, 12)
            }
            .padding(.horizontal, 24)
        }
    }

    private func lineProgress(_ idx: Int, current: Int, t: Double) -> (syllable: Int, fraction: Double) {
        if idx == current { return player.lyrics.progress(line: idx, at: t) }
        return idx < current ? (syllable: Int.max, fraction: 1) : (syllable: -1, fraction: 0)
    }

    private func visibleLines(current: Int) -> [Int] {
        let n = player.lyrics.lines.count
        if current < 0 { return Array(0..<min(2, n)) }
        return [current, current + 1].filter { $0 < n }
    }

    /// Accordi che cadono nella riga, ciascuno associato alla sillaba più vicina.
    private func chordsFor(line idx: Int) -> [(Int, String)] {
        let line = player.lyrics.lines[idx]
        guard let st = line.syllables.first?.time, st >= 0 else { return [] }
        let nextStart = idx + 1 < player.lyrics.lines.count ? player.lyrics.lines[idx + 1].startTime : st + 8
        let end = nextStart > st ? nextStart : st + 8
        var out: [(Int, String)] = []
        for c in player.chords where c.time >= st - 0.3 && c.time < end - 0.3 {
            var best = 0
            for (si, s) in line.syllables.enumerated() where s.time >= 0 && s.time <= c.time + 0.25 { best = si }
            if out.last?.0 == best { out[out.count - 1].1 = player.displayChord(c.chord) } else { out.append((best, player.displayChord(c.chord))) }
        }
        return out
    }

    @ViewBuilder
    private func countdownDots(_ remaining: Double, fs: CGFloat) -> some View {
        if remaining > 0 && remaining < 5 {
            HStack(spacing: fs * 0.25) {
                ForEach(0..<4, id: \.self) { i in
                    Circle().fill(Double(4 - i) <= remaining.rounded(.up) ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.line))
                        .frame(width: fs * 0.28, height: fs * 0.28)
                }
            }.padding(.top, fs * 0.3)
        }
    }
}

struct LyricLineView: View {
    var line: LyricLine
    var active: Bool
    var time: Double
    var progress: (syllable: Int, fraction: Double)
    var chords: [(Int, String)]
    var fontSize: CGFloat

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(line.syllables.enumerated()), id: \.offset) { i, s in
                VStack(alignment: .leading, spacing: 0) {
                    if !chords.isEmpty {
                        Text(chords.first(where: { $0.0 == i })?.1 ?? " ")
                            .font(.system(size: fontSize * 0.42, weight: .bold, design: .rounded))
                            .foregroundColor(Theme.cyan)
                            .fixedSize()
                    }
                    syllable(s.text, index: i)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.4)
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private func syllable(_ text: String, index i: Int) -> some View {
        let base = Text(text).font(.system(size: fontSize, weight: .heavy, design: .rounded))
        let f: Double = i < progress.syllable ? 1 : (i == progress.syllable ? progress.fraction : 0)
        base.foregroundColor(Theme.ink)
            .overlay(
                GeometryReader { g in
                    Rectangle().fill(Theme.gradient)
                        .frame(width: g.size.width * CGFloat(f))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .mask(base)
            )
            .fixedSize()
    }
}

/// Livello video AppKit (lo stesso AVPlayer può comparire anche sul secondo schermo).
struct VideoLayerView: NSViewRepresentable {
    var player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let l = AVPlayerLayer(player: player)
        l.videoGravity = .resizeAspect
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = CALayer()
        v.layer?.backgroundColor = NSColor.black.cgColor
        v.layer?.addSublayer(l)
        l.frame = v.bounds
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        if let l = v.layer?.sublayers?.first as? AVPlayerLayer {
            if l.player !== player { l.player = player }
            l.frame = v.bounds
        }
    }
}

/// Finestra del testo sul secondo schermo (TV/proiettore), a tutto schermo.
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()
    @Published private(set) var isOpen = false
    private var window: NSWindow?

    func toggle(player: KaraokePlayer) { isOpen ? close() : open(player: player) }

    func open(player: KaraokePlayer) {
        let screens = NSScreen.screens
        let target = screens.count > 1 ? screens[1] : (NSScreen.main ?? screens[0])
        let w = NSWindow(contentRect: target.frame, styleMask: screens.count > 1 ? [.borderless] : [.titled, .resizable, .closable],
                         backing: .buffered, defer: false, screen: target)
        w.title = "FPM Studio Live – Schermo karaoke"
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: LyricsStageView(player: player, fontScale: 1.25))
        if screens.count > 1 {
            w.setFrame(target.frame, display: true)
            w.level = .normal
            w.collectionBehavior = [.fullScreenPrimary]
        } else {
            w.setContentSize(NSSize(width: 1100, height: 620))
            w.center()
        }
        w.makeKeyAndOrderFront(nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            self?.isOpen = false
            self?.window = nil
        }
        window = w
        isOpen = true
    }

    func close() {
        window?.close()
        window = nil
        isOpen = false
    }
}
