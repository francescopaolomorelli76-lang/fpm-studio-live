import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

// MARK: - Chord Bar (C04): accordo corrente e successivi, tastiera di pianoforte e diagramma chitarra

struct ChordBarView: View {
    @ObservedObject var player: KaraokePlayer
    @ObservedObject var clock: PlaybackClock

    init(player: KaraokePlayer) { self.player = player; self.clock = player.clock }

    var body: some View {
        let t = player.lyricsTime
        let idx = player.currentChordIndex(at: t)
        let current = idx.flatMap { player.chords[$0].chord }?.transposed(player.transpose)
        HStack(alignment: .center, spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(upcoming(from: idx).enumerated()), id: \.offset) { k, c in
                        Text(player.displayChord(c.chord))
                            .font(.system(size: k == 0 ? 26 : 16, weight: .heavy, design: .rounded))
                            .foregroundColor(k == 0 ? Theme.cyan : Theme.soft)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(k == 0 ? Theme.violet.opacity(0.3) : Theme.bg2))
                    }
                }
            }
            if let c = current {
                PianoChordView(chord: c).frame(width: 220, height: 64)
                GuitarChordView(chord: c).frame(width: 90, height: 110)
            }
        }
    }

    private func upcoming(from i: Int?) -> [ChordEvent] {
        guard let i = i else { return Array(player.chords.prefix(8)) }
        return Array(player.chords[i..<min(player.chords.count, i + 8)])
    }
}

struct PianoChordView: View {
    var chord: Chord
    var body: some View {
        let d = ChordDiagrams.piano(chord)
        let lit = Set(d.notes)
        let low = 48, high = 84
        Canvas { ctx, size in
            let whites = (low...high).filter { ![1, 3, 6, 8, 10].contains($0 % 12) }
            let w = size.width / CGFloat(whites.count)
            var x: CGFloat = 0
            var whiteX: [Int: CGFloat] = [:]
            for n in whites {
                whiteX[n] = x
                let on = lit.contains(n) || n == d.bass
                ctx.fill(Path(CGRect(x: x + 0.5, y: 0, width: w - 1, height: size.height)),
                         with: .color(on ? (n == d.bass ? Color(red: 0.88, green: 0.3, blue: 0.98) : Color(red: 0, green: 0.9, blue: 1)) : .white))
                x += w
            }
            for n in low...high where [1, 3, 6, 8, 10].contains(n % 12) {
                guard let lx = whiteX[n - 1] else { continue }
                let on = lit.contains(n) || n == d.bass
                ctx.fill(Path(CGRect(x: lx + w * 0.65, y: 0, width: w * 0.7, height: size.height * 0.6)),
                         with: .color(on ? (n == d.bass ? Color(red: 0.88, green: 0.3, blue: 0.98) : Color(red: 0, green: 0.9, blue: 1)) : .black))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct GuitarChordView: View {
    var chord: Chord
    var body: some View {
        let g = ChordDiagrams.guitar(chord)
        Canvas { ctx, size in
            let top: CGFloat = 16, left: CGFloat = 12, right: CGFloat = 8
            let sw = (size.width - left - right) / 5
            let fh = (size.height - top - 6) / 5
            let ink = Color(red: 0.95, green: 0.96, blue: 1)
            for s in 0..<6 {
                var p = Path(); p.move(to: CGPoint(x: left + CGFloat(s) * sw, y: top)); p.addLine(to: CGPoint(x: left + CGFloat(s) * sw, y: top + fh * 5))
                ctx.stroke(p, with: .color(ink.opacity(0.7)), lineWidth: 1)
            }
            for f in 0...5 {
                var p = Path(); p.move(to: CGPoint(x: left, y: top + CGFloat(f) * fh)); p.addLine(to: CGPoint(x: left + sw * 5, y: top + CGFloat(f) * fh))
                ctx.stroke(p, with: .color(ink.opacity(f == 0 && g.baseFret == 1 ? 1 : 0.5)), lineWidth: f == 0 && g.baseFret == 1 ? 3 : 1)
            }
            if g.baseFret > 1 {
                ctx.draw(Text("\(g.baseFret)").font(.system(size: 9)).foregroundColor(ink), at: CGPoint(x: 4, y: top + fh / 2))
            }
            for (s, fret) in g.frets.enumerated() {
                let x = left + CGFloat(s) * sw
                if fret < 0 {
                    ctx.draw(Text("×").font(.system(size: 10)).foregroundColor(ink), at: CGPoint(x: x, y: 7))
                } else if fret == 0 {
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - 4, y: 3, width: 8, height: 8)), with: .color(ink), lineWidth: 1)
                } else {
                    let row = CGFloat(fret - g.baseFret) + 0.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 5, y: top + row * fh - 5, width: 10, height: 10)), with: .color(Color(red: 0, green: 0.9, blue: 1)))
                }
            }
        }
    }
}

// MARK: - Leggio PDF/TXT/RTF (C08, I02) con cambio pagina da evento, tastiera o pedale

struct LeggioView: View {
    @ObservedObject var player: KaraokePlayer

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text(player.documentURL?.lastPathComponent ?? "Nessun documento: scegli un PDF/TXT/RTF (oppure mettilo accanto al brano con lo stesso nome)")
                    .font(.caption).foregroundColor(Theme.soft).lineLimit(1)
                Spacer()
                Button("Scegli documento…") { choose() }.buttonStyle(NeonButtonStyle(prominent: false)).disabled(player.item == nil)
                if player.documentURL != nil {
                    Button(action: { player.pdfPage = max(1, player.pdfPage - 1) }) { Image(systemName: "chevron.left") }.buttonStyle(NeonButtonStyle(prominent: false))
                    Text("Pag. \(player.pdfPage)").monospacedDigit()
                    Button(action: { player.pdfPage += 1 }) { Image(systemName: "chevron.right") }.buttonStyle(NeonButtonStyle(prominent: false))
                }
            }
            if let u = player.documentURL {
                if u.pathExtension.lowercased() == "pdf" {
                    PDFLeggio(url: u, page: $player.pdfPage)
                } else {
                    TextLeggio(url: u)
                }
            } else {
                Spacer()
            }
        }
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .plainText, .rtf]
        if p.runModal() == .OK, let u = p.url {
            player.documentURL = u
            player.pdfPage = 1
            player.saveSidecar()
        }
    }
}

struct PDFLeggio: NSViewRepresentable {
    var url: URL
    @Binding var page: Int

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePage
        v.backgroundColor = .black
        v.document = PDFDocument(url: url)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
        guard let doc = v.document, doc.pageCount > 0 else { return }
        let i = max(0, min(doc.pageCount - 1, page - 1))
        if page - 1 != i { DispatchQueue.main.async { page = i + 1 } }
        if let pg = doc.page(at: i), v.currentPage != pg { v.go(to: pg) }
    }
}

struct TextLeggio: View {
    var url: URL
    var body: some View {
        ScrollView {
            Text(load()).font(.system(size: 22, weight: .medium, design: .rounded)).frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
    }
    private func load() -> String {
        if url.pathExtension.lowercased() == "rtf", let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) { return a.string }
        return (try? String(contentsOf: url)) ?? (try? String(contentsOf: url, encoding: .windowsCP1252)) ?? ""
    }
}
