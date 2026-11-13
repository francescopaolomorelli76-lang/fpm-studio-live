import SwiftUI
import AppKit

/// Maxi schermo della tombola: numero estratto in grande, simbolo e detto della Smorfia, tabellone dei 90,
/// logo del locale, QR per partecipare e, sotto Natale, neve e lucine.
struct TombolaStageView: View {
    @ObservedObject var game: TombolaGame

    private let gold = Color(red: 1.0, green: 0.82, blue: 0.4)
    private let cream = Color(red: 1.0, green: 0.97, blue: 0.92)
    private let xmasRed = Color(red: 0.85, green: 0.12, blue: 0.2)

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width / 1600, geo.size.height / 900)
            ZStack {
                background
                if game.christmas { SnowView().allowsHitTesting(false); ChristmasLights().frame(height: 26 * s).frame(maxHeight: .infinity, alignment: .top) }
                VStack(spacing: 18 * s) {
                    topBar(s)
                    HStack(alignment: .top, spacing: 36 * s) {
                        mainNumber(s).frame(width: geo.size.width * 0.52)
                        board(s)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 44 * s).padding(.top, 40 * s).padding(.bottom, 24 * s)
                if let w = game.banner { winBanner(w, s) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(Color.black)
    }

    private var background: some View {
        Group {
            if game.christmas {
                ZStack {
                    LinearGradient(gradient: Gradient(colors: [Color(red: 0.03, green: 0.12, blue: 0.09), Color(red: 0.02, green: 0.06, blue: 0.05), Color(red: 0.18, green: 0.03, blue: 0.07)]),
                                   startPoint: .top, endPoint: .bottom)
                    RadialGradient(gradient: Gradient(colors: [gold.opacity(0.18), .clear]), center: .init(x: 0.28, y: 0.45), startRadius: 10, endRadius: 600)
                }
            } else {
                Theme.background
            }
        }
    }

    private func topBar(_ s: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 20 * s) {
            if let img = game.logo {
                Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 220 * s, maxHeight: 110 * s)
            } else {
                Image("Logo").resizable().scaledToFit().frame(width: 96 * s, height: 96 * s).clipShape(RoundedRectangle(cornerRadius: 20 * s))
            }
            VStack(alignment: .leading, spacing: 4 * s) {
                Text(game.christmas ? "🎄 Tombola napoletana" : "Tombola napoletana")
                    .font(.system(size: 58 * s, weight: .black, design: .rounded)).foregroundColor(gold)
                    .shadow(color: gold.opacity(0.6), radius: 14 * s)
                Text(game.venueName.isEmpty ? (game.christmas ? "Buone feste!" : "FPM Studio Live") : game.venueName + (game.christmas ? " · Buone feste!" : ""))
                    .font(.system(size: 26 * s, weight: .semibold)).foregroundColor(cream.opacity(0.85))
            }
            Spacer()
            if let qr = game.qr {
                HStack(spacing: 14 * s) {
                    VStack(alignment: .trailing, spacing: 4 * s) {
                        Text("Gioca dal telefono").font(.system(size: 24 * s, weight: .heavy)).foregroundColor(gold)
                        Text("Inquadra il QR e scegli\nla tua cartella").font(.system(size: 18 * s)).foregroundColor(cream.opacity(0.8)).multilineTextAlignment(.trailing)
                        Text("Stessa rete Wi-Fi del locale").font(.system(size: 13 * s)).foregroundColor(cream.opacity(0.55))
                    }
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 150 * s, height: 150 * s)
                        .padding(8 * s).background(RoundedRectangle(cornerRadius: 12 * s).fill(Color.white))
                }
            }
        }
    }

    private func mainNumber(_ s: CGFloat) -> some View {
        VStack(spacing: 16 * s) {
            if let n = game.current {
                let e = game.smorfia(n)
                HStack(spacing: 30 * s) {
                    ZStack {
                        Circle().fill(RadialGradient(gradient: Gradient(colors: [Color(red: 1, green: 0.98, blue: 0.85), gold, Color(red: 0.8, green: 0.58, blue: 0.1)]),
                                                     center: .init(x: 0.35, y: 0.3), startRadius: 4, endRadius: 230 * s))
                            .shadow(color: gold.opacity(0.75), radius: 40 * s)
                        Text("\(n)").font(.system(size: 210 * s, weight: .black, design: .rounded)).foregroundColor(Color(red: 0.3, green: 0.04, blue: 0.08))
                            .minimumScaleFactor(0.5)
                    }
                    .frame(width: 360 * s, height: 360 * s)
                    .id(n)
                    .transition(.asymmetric(insertion: .scale(scale: 0.2).combined(with: .opacity), removal: .opacity))
                    Text(e.simbolo).font(.system(size: 170 * s)).id("sym\(n)").transition(.scale.combined(with: .opacity))
                }
                .animation(.spring(response: 0.7, dampingFraction: 0.55), value: n)
                Text(e.napoletano).font(.system(size: 64 * s, weight: .heavy, design: .rounded)).foregroundColor(gold)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.5)
                    .shadow(color: .black.opacity(0.6), radius: 4 * s)
                Text(e.italiano).font(.system(size: 34 * s, weight: .semibold)).foregroundColor(cream.opacity(0.85))
            } else {
                Text(game.christmas ? "🎅" : "🎲").font(.system(size: 200 * s))
                Text(game.finished ? "Partita finita" : "Si comincia tra poco!").font(.system(size: 60 * s, weight: .heavy, design: .rounded)).foregroundColor(gold)
                Text("Inquadra il QR e scegli la tua cartella").font(.system(size: 30 * s)).foregroundColor(cream.opacity(0.85))
            }
            Spacer(minLength: 8 * s)
            statusRow(s)
        }
    }

    private func statusRow(_ s: CGFloat) -> some View {
        HStack(spacing: 22 * s) {
            pill(title: "In palio", value: game.finished ? "—" : (game.currentPrize?.name ?? "—"), s)
            if game.finished {
                pill(title: "Partita", value: "Finita", s)
            } else if game.running {
                ZStack {
                    Circle().stroke(cream.opacity(0.15), lineWidth: 10 * s)
                    Circle().trim(from: 0, to: CGFloat(Double(game.secondsToNext) / max(1, game.intervalSeconds)))
                        .stroke(xmasRed, style: StrokeStyle(lineWidth: 10 * s, lineCap: .round)).rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: game.secondsToNext)
                    VStack(spacing: 0) {
                        Text(formatTime(Double(game.secondsToNext))).font(.system(size: 30 * s, weight: .bold, design: .monospaced)).foregroundColor(cream)
                        Text("prossimo").font(.system(size: 13 * s)).foregroundColor(cream.opacity(0.6))
                    }
                }.frame(width: 120 * s, height: 120 * s)
            } else {
                pill(title: "Gioco", value: "In pausa", s)
            }
            pill(title: "Usciti", value: "\(game.drawn.count)/90", s)
            pill(title: "Cartelle in gioco", value: "\(game.players.count)", s)
        }
    }

    private func pill(title: String, value: String, _ s: CGFloat) -> some View {
        VStack(spacing: 2 * s) {
            Text(title.uppercased()).font(.system(size: 13 * s, weight: .bold)).tracking(1.5 * s).foregroundColor(cream.opacity(0.6))
            Text(value).font(.system(size: 34 * s, weight: .heavy, design: .rounded)).foregroundColor(gold)
        }
        .padding(.horizontal, 20 * s).padding(.vertical, 12 * s)
        .background(RoundedRectangle(cornerRadius: 18 * s).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 18 * s).stroke(gold.opacity(0.35), lineWidth: 1))
    }

    private func board(_ s: CGFloat) -> some View {
        let drawn = game.drawnSet
        return VStack(alignment: .leading, spacing: 10 * s) {
            Text("TABELLONE").font(.system(size: 16 * s, weight: .heavy)).tracking(3 * s).foregroundColor(cream.opacity(0.7))
            VStack(spacing: 6 * s) {
                ForEach(0..<9, id: \.self) { r in
                    HStack(spacing: 6 * s) {
                        ForEach(1...10, id: \.self) { c in
                            let n = r * 10 + c
                            let on = drawn.contains(n)
                            let isLast = n == game.current
                            Text("\(n)")
                                .font(.system(size: 26 * s, weight: .heavy, design: .rounded))
                                .foregroundColor(on ? Color(red: 0.3, green: 0.04, blue: 0.08) : cream.opacity(0.35))
                                .frame(maxWidth: .infinity).frame(height: 52 * s)
                                .background(RoundedRectangle(cornerRadius: 10 * s).fill(on ? (isLast ? Color.white : gold) : Color.white.opacity(0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 10 * s).stroke(isLast ? xmasRed : Color.clear, lineWidth: 4 * s))
                                .shadow(color: on ? gold.opacity(0.5) : .clear, radius: 6 * s)
                        }
                    }
                }
            }
            if !game.drawn.isEmpty {
                Text("ULTIMI NUMERI").font(.system(size: 16 * s, weight: .heavy)).tracking(3 * s).foregroundColor(cream.opacity(0.7)).padding(.top, 8 * s)
                HStack(spacing: 10 * s) {
                    ForEach(Array(game.drawn.suffix(6).reversed()), id: \.self) { n in
                        VStack(spacing: 2 * s) {
                            Text("\(n)").font(.system(size: 30 * s, weight: .black, design: .rounded)).foregroundColor(cream)
                            Text(game.smorfia(n).simbolo).font(.system(size: 26 * s))
                        }
                        .frame(width: 78 * s, height: 86 * s)
                        .background(RoundedRectangle(cornerRadius: 14 * s).fill(xmasRed.opacity(n == game.current ? 0.9 : 0.45)))
                    }
                }
            }
            if !game.winners.isEmpty {
                VStack(alignment: .leading, spacing: 4 * s) {
                    ForEach(game.winners) { w in
                        Text("🏆 " + w.text).font(.system(size: 20 * s, weight: .bold)).foregroundColor(gold).lineLimit(1).minimumScaleFactor(0.6)
                    }
                }.padding(.top, 8 * s)
            }
        }
    }

    private func winBanner(_ w: TombolaGame.Win, _ s: CGFloat) -> some View {
        VStack(spacing: 16 * s) {
            Text(w.prize == .tombola ? "🎉🎄 TOMBOLA! 🎄🎉" : "🎉 \(w.prize.name.uppercased())! 🎉")
                .font(.system(size: 130 * s, weight: .black, design: .rounded)).foregroundColor(gold)
                .shadow(color: gold.opacity(0.8), radius: 30 * s)
            Text("Cartella " + w.cards.map { "n. \($0)" }.joined(separator: ", "))
                .font(.system(size: 60 * s, weight: .heavy)).foregroundColor(cream)
            let names = w.names.filter { !$0.isEmpty }
            if !names.isEmpty { Text("Complimenti " + names.joined(separator: ", ") + "!").font(.system(size: 44 * s, weight: .semibold)).foregroundColor(cream.opacity(0.9)) }
            Text("Presentati al banco con il telefono").font(.system(size: 28 * s)).foregroundColor(cream.opacity(0.7))
        }
        .padding(60 * s)
        .background(RoundedRectangle(cornerRadius: 40 * s).fill(Color(red: 0.35, green: 0.03, blue: 0.08).opacity(0.94)))
        .overlay(RoundedRectangle(cornerRadius: 40 * s).stroke(gold, lineWidth: 4 * s))
        .shadow(color: .black.opacity(0.6), radius: 40 * s)
        .transition(.scale.combined(with: .opacity))
    }
}

/// Neve che cade (macOS 12: TimelineView + Canvas).
struct SnowView: View {
    private struct Flake { let x: Double; let speed: Double; let size: Double; let phase: Double; let delay: Double }
    private let flakes: [Flake] = (0..<140).map { i in
        var g = SeededRandom(seed: UInt64(i) &* 2654435761 &+ 17)
        return Flake(x: g.next01(), speed: 0.04 + g.next01() * 0.09, size: 1.5 + g.next01() * 4.5, phase: g.next01() * 6.28, delay: g.next01())
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            Canvas { gc, size in
                let t = ctx.date.timeIntervalSinceReferenceDate
                for f in flakes {
                    let y = ((t * f.speed + f.delay).truncatingRemainder(dividingBy: 1.0)) * (size.height + 20) - 10
                    let x = f.x * size.width + sin(t * 0.8 + f.phase) * 18
                    let r = f.size * max(1, size.width / 1600)
                    gc.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)), with: .color(.white.opacity(0.75)))
                }
            }
        }
    }
}

/// Fila di lucine natalizie che lampeggiano.
struct ChristmasLights: View {
    private let colors: [Color] = [Color(red: 1, green: 0.3, blue: 0.43), Color(red: 1, green: 0.82, blue: 0.4), Color(red: 0.02, green: 0.84, blue: 0.63), Color(red: 0.3, green: 0.79, blue: 0.94)]
    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.7)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.7)
            GeometryReader { geo in
                let n = max(8, Int(geo.size.width / 46))
                ZStack(alignment: .topLeading) {
                    Path { p in
                        p.move(to: .zero)
                        for i in 0...n {
                            let x = geo.size.width * CGFloat(i) / CGFloat(n)
                            p.addQuadCurve(to: CGPoint(x: x, y: 0), control: CGPoint(x: x - geo.size.width / CGFloat(n) / 2, y: geo.size.height * 0.5))
                        }
                    }.stroke(Color(red: 0.1, green: 0.25, blue: 0.15), lineWidth: 2)
                    ForEach(0..<n, id: \.self) { i in
                        let on = (i + phase) % 3 != 0
                        Capsule().fill(colors[i % colors.count].opacity(on ? 1 : 0.25))
                            .shadow(color: on ? colors[i % colors.count] : .clear, radius: 8)
                            .frame(width: geo.size.height * 0.45, height: geo.size.height * 0.7)
                            .position(x: geo.size.width * (CGFloat(i) + 0.5) / CGFloat(n), y: geo.size.height * 0.55)
                    }
                }
            }
        }
    }
}

/// Generatore pseudo-casuale con seme (per una neve sempre uguale tra un'apertura e l'altra).
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func next01() -> Double { Double(next() % 1_000_000) / 1_000_000 }
}

/// Finestra del maxi schermo (secondo monitor o TV), a tutto schermo.
final class TombolaDisplay: ObservableObject {
    static let shared = TombolaDisplay()
    @Published private(set) var isOpen = false
    private var window: NSWindow?

    func toggle(game: TombolaGame) { isOpen ? close() : open(game: game) }

    func open(game: TombolaGame) {
        let screens = NSScreen.screens
        let target = screens.count > 1 ? screens[1] : (NSScreen.main ?? screens[0])
        let w = NSWindow(contentRect: target.frame, styleMask: screens.count > 1 ? [.borderless] : [.titled, .resizable, .closable],
                         backing: .buffered, defer: false, screen: target)
        w.title = "FPM Studio Live – Tombola"
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: TombolaStageView(game: game))
        if screens.count > 1 {
            w.setFrame(target.frame, display: true)
        } else {
            w.setContentSize(NSSize(width: 1280, height: 720))
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
