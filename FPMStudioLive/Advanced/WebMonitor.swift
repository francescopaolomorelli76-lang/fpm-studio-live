import Foundation
import Network
import AppKit
import CoreImage
import Combine

/// Karaoke Web Monitor (C07) e telecomando (L01) sulla rete locale.
/// - Monitor: chiunque abbia il link/QR vede il testo sincronizzato e sceglie font, dimensione e colori.
/// - Telecomando (facoltativo, con PIN): play/pausa, stop, tono, brano successivo.
/// Funziona solo sulla stessa rete Wi-Fi (non su Internet). La sessione scade quando si ferma il server.
final class WebMonitor: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var url: String = ""
    @Published private(set) var remoteURL: String = ""
    @Published private(set) var qr: NSImage?
    @Published private(set) var clients = 0
    @Published var allowRemote = false
    @Published var error: String?

    let port: UInt16 = 8090
    private var listener: NWListener?
    private var token = ""
    private(set) var pin = ""
    weak var player: KaraokePlayer?
    private var snapshot = Data("{}".utf8)
    private var timer: Timer?
    private var seenClients: [String: Date] = [:]

    func toggle() { running ? stop() : start() }

    func start() {
        guard !running else { return }
        token = String(UUID().uuidString.prefix(8)).lowercased()
        pin = String(format: "%04d", Int.random(in: 0...9999))
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    if case .failed(let e) = st { self?.error = "Server non avviato: \(e.localizedDescription)"; self?.stop() }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            self.error = "Server non avviato: \(error.localizedDescription)"
            return
        }
        let ip = WebMonitor.localIPv4() ?? "localhost"
        url = "http://\(ip):\(port)/k/\(token)"
        remoteURL = "http://\(ip):\(port)/r/\(token)"
        qr = WebMonitor.qrImage(url)
        running = true
        error = nil
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.refreshSnapshot() }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        timer?.invalidate()
        running = false
        url = ""; remoteURL = ""; qr = nil; clients = 0
    }

    /// Stato corrente in JSON (aggiornato 5 volte al secondo sul thread principale).
    private func refreshSnapshot() {
        guard let p = player else { return }
        let t = p.lyricsTime
        var line = "", next = "", sung = 0
        if let li = p.lyrics.lineIndex(at: t) {
            let l = p.lyrics.lines[li]
            line = l.text
            let pr = p.lyrics.progress(line: li, at: t)
            // Caratteri già cantati.
            if pr.syllable >= 0 {
                let done = l.syllables.prefix(pr.syllable).map { $0.text }.joined()
                let cur = pr.syllable < l.syllables.count ? l.syllables[pr.syllable].text : ""
                sung = done.count + Int(Double(cur.count) * pr.fraction)
            }
            if li + 1 < p.lyrics.lines.count { next = p.lyrics.lines[li + 1].text }
        } else if let first = p.lyrics.lines.first {
            next = first.text
        }
        var chord = ""
        if let ci = p.currentChordIndex(at: t), AppSettings.shared.showChords { chord = p.displayChord(p.chords[ci].chord) }
        let obj: [String: Any] = [
            "title": p.item?.title ?? "FPM Studio Live", "artist": p.item?.artist ?? "",
            "line": line, "next": next, "sung": sung, "chord": chord,
            "playing": p.isPlaying, "banner": p.banner ?? "", "transpose": p.transpose
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj) { snapshot = d }
        let now = Date()
        seenClients = seenClients.filter { now.timeIntervalSince($0.value) < 3 }
        clients = seenClients.count
    }

    // MARK: HTTP minimale

    private func handle(_ c: NWConnection) {
        c.start(queue: .global(qos: .userInitiated))
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let firstLine = req.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            let peer = "\(c.endpoint)"
            self.route(path, peer: peer) { status, type, body in
                var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
                c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    private func route(_ path: String, peer: String, reply: @escaping (String, String, Data) -> Void) {
        let comps = path.split(separator: "?", maxSplits: 1)
        let p = String(comps.first ?? "")
        let query = comps.count > 1 ? String(comps[1]) : ""
        let seg = p.split(separator: "/").map(String.init)
        guard seg.count >= 2, seg[1] == token else { reply("404 Not Found", "text/plain", Data("Sessione scaduta o link non valido".utf8)); return }
        switch (seg[0], seg.count > 2 ? seg[2] : "") {
        case ("k", ""): reply("200 OK", "text/html; charset=utf-8", Data(WebMonitor.monitorHTML.utf8))
        case ("k", "state"), ("r", "state"):
            DispatchQueue.main.async {
                self.seenClients[peer.components(separatedBy: ":").first ?? peer] = Date()
                reply("200 OK", "application/json", self.snapshot)
            }
        case ("r", ""): reply("200 OK", "text/html; charset=utf-8", Data(WebMonitor.remoteHTML.utf8))
        case ("r", "cmd"):
            let params = Dictionary(uniqueKeysWithValues: query.split(separator: "&").compactMap { kv -> (String, String)? in
                let a = kv.split(separator: "=", maxSplits: 1); return a.count == 2 ? (String(a[0]), String(a[1])) : nil })
            DispatchQueue.main.async {
                guard self.allowRemote, params["pin"] == self.pin, let p = self.player else {
                    reply("403 Forbidden", "text/plain", Data("Telecomando non abilitato o PIN errato".utf8)); return
                }
                switch params["c"] ?? "" {
                case "play": p.togglePlay()
                case "stop": p.stop()
                case "next": p.playNextNow()
                case "up": p.transpose = min(12, p.transpose + 1)
                case "down": p.transpose = max(-12, p.transpose - 1)
                case "fade": p.fadeOut()
                default: break
                }
                reply("200 OK", "text/plain", Data("ok".utf8))
            }
        default:
            reply("404 Not Found", "text/plain", Data("Non trovato".utf8))
        }
    }

    // MARK: Utilità

    static func localIPv4() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: i.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            addr = String(cString: host)
            if name == "en0" { break }
        }
        return addr
    }

    static func qrImage(_ s: String) -> NSImage? {
        guard let f = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        f.setValue(Data(s.utf8), forKey: "inputMessage")
        f.setValue("M", forKey: "inputCorrectionLevel")
        guard let img = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: img)
        let ns = NSImage(size: rep.size)
        ns.addRepresentation(rep)
        return ns
    }

    static let monitorHTML = """
    <!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>FPM Karaoke</title><style>
    :root{--bg:#070a1f;--ink:#f2f4ff;--hi:#00e5ff;--hi2:#e04cfa;--size:9vw;--font:system-ui}
    body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--font);height:100vh;display:flex;flex-direction:column;justify-content:center;text-align:center;overflow:hidden}
    #t{opacity:.6;font-size:4vw;margin-bottom:4vh}#l{font-size:var(--size);font-weight:800;line-height:1.15;padding:0 3vw}
    #l .s{background:linear-gradient(90deg,var(--hi),var(--hi2));-webkit-background-clip:text;color:transparent}
    #n{font-size:calc(var(--size)*.7);opacity:.5;margin-top:3vh;padding:0 3vw}#c{color:var(--hi);font-size:6vw;font-weight:800;min-height:7vw}
    #b{position:fixed;bottom:0;left:0;right:0;background:#e04cfa;color:#fff;font-size:5vw;padding:1vh;display:none}
    #o{position:fixed;top:8px;right:8px;opacity:.5}#p{position:fixed;top:44px;right:8px;background:#141838;padding:10px;border-radius:10px;display:none;text-align:left}
    button,select,input{font-size:16px}
    </style></head><body>
    <div id="t"></div><div id="c"></div><div id="l"></div><div id="n"></div><div id="b"></div>
    <button id="o" onclick="p.style.display=p.style.display=='block'?'none':'block'">Aa</button>
    <div id="p">Dimensione <input type="range" min="4" max="16" id="sz"><br>Carattere <select id="fn"><option>system-ui</option><option>Georgia</option><option>Verdana</option><option>Arial Black</option></select><br>
    Sfondo <input type="color" id="bg" value="#070a1f"> Testo <input type="color" id="ik" value="#f2f4ff"><br>Evidenziato <input type="color" id="hc" value="#00e5ff"></div>
    <script>
    const r=document.documentElement.style,q=k=>localStorage.getItem('fpm_'+k),s=(k,v)=>localStorage.setItem('fpm_'+k,v);
    function apply(){if(q('sz'))r.setProperty('--size',q('sz')+'vw');if(q('fn'))r.setProperty('--font',q('fn'));if(q('bg'))r.setProperty('--bg',q('bg'));if(q('ik'))r.setProperty('--ink',q('ik'));if(q('hc')){r.setProperty('--hi',q('hc'));r.setProperty('--hi2',q('hc'))}}
    [['sz','input'],['fn','change'],['bg','input'],['ik','input'],['hc','input']].forEach(([id,ev])=>{const e=document.getElementById(id);if(q(id))e.value=q(id);e.addEventListener(ev,()=>{s(id,e.value);apply()})});apply();
    const esc=x=>x.replace(/[&<>]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;'}[c]));
    async function tick(){try{const j=await (await fetch(location.pathname.replace(/\\/$/,'')+'/state',{cache:'no-store'})).json();
    t.textContent=j.title+(j.artist?' – '+j.artist:'');c.textContent=j.chord;const a=j.line.slice(0,j.sung),b2=j.line.slice(j.sung);
    l.innerHTML='<span class="s">'+esc(a)+'</span>'+esc(b2);n.textContent=j.next;b.style.display=j.banner?'block':'none';b.textContent=j.banner;}catch(e){}
    setTimeout(tick,200)}tick();
    </script></body></html>
    """

    static let remoteHTML = """
    <!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>FPM Telecomando</title>
    <style>body{background:#070a1f;color:#f2f4ff;font-family:system-ui;text-align:center;padding:16px}button{font-size:22px;margin:6px;padding:16px 22px;border-radius:14px;border:0;background:linear-gradient(90deg,#00e5ff,#8e5bff,#e04cfa);color:#fff;min-width:42%}
    input{font-size:22px;width:120px;text-align:center}#s{opacity:.7;margin:10px}</style></head><body>
    <h2>FPM Studio Live</h2><div id="s"></div>PIN <input id="pin" inputmode="numeric" maxlength="4"><br>
    <button onclick="c('play')">▶︎ / ❚❚</button><button onclick="c('stop')">■ Stop</button><button onclick="c('down')">Tono −</button><button onclick="c('up')">Tono +</button>
    <button onclick="c('fade')">Fade out</button><button onclick="c('next')">Successivo ⏭</button>
    <script>pin.value=localStorage.getItem('fpm_pin')||'';pin.oninput=()=>localStorage.setItem('fpm_pin',pin.value);
    const base=location.pathname.replace(/\\/$/,'');async function c(x){const r=await fetch(base+'/cmd?c='+x+'&pin='+pin.value);if(!r.ok)alert(await r.text())}
    async function st(){try{const j=await (await fetch(base+'/state')).json();s.textContent=(j.playing?'▶︎ ':'❚❚ ')+j.title+' · tono '+j.transpose}catch(e){}setTimeout(st,1000)}st();</script></body></html>
    """
}
