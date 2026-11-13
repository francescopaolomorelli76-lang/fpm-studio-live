import Foundation
import AppKit
import AVFoundation
import Network
import UniformTypeIdentifiers

/// Tombola napoletana per i locali: l'app estrae i numeri a intervalli regolari, li annuncia a voce
/// (prima il numero, poi il detto della Smorfia in napoletano), li mostra sul maxi schermo
/// e i clienti giocano dal telefono con la cartella scelta dopo aver inquadrato il QR.
final class TombolaGame: ObservableObject {
    struct Player: Codable, Equatable { var name: String; var clientID: String }
    struct Win: Identifiable, Equatable {
        let id = UUID()
        let prize: TombolaPrize
        let cards: [Int]
        let names: [String]
        let number: Int
        var text: String {
            let c = cards.map { "n. \($0)" }.joined(separator: ", ")
            let n = names.filter { !$0.isEmpty }.joined(separator: ", ")
            return "\(prize.name.uppercased())! Cartella \(c)" + (n.isEmpty ? "" : " – \(n)")
        }
    }

    // MARK: Impostazioni (salvate)
    private let d = UserDefaults.standard
    @Published var intervalSeconds: Double { didSet { d.set(intervalSeconds, forKey: "tmb.interval"); if running { reschedule() } } }
    @Published var repeatDelay: Double { didSet { d.set(repeatDelay, forKey: "tmb.repeat") } }
    @Published var seriesCount: Int { didSet { d.set(seriesCount, forKey: "tmb.series") } }
    @Published var familyMode: Bool { didSet { d.set(familyMode, forKey: "tmb.family") } }
    @Published var christmas: Bool { didSet { d.set(christmas, forKey: "tmb.xmas") } }
    @Published var pauseAfterWin: Bool { didSet { d.set(pauseAfterWin, forKey: "tmb.pauseWin") } }
    @Published var venueName: String { didSet { d.set(venueName, forKey: "tmb.venue") } }
    @Published var voiceID: String { didSet { d.set(voiceID, forKey: "tmb.voice"); voice.voiceID = voiceID } }
    @Published var useElevenLabs: Bool { didSet { d.set(useElevenLabs, forKey: "tmb.eleven"); voice.useEleven = useElevenLabs } }
    @Published var elevenVoiceID: String { didSet { d.set(elevenVoiceID, forKey: "tmb.elevenVoice"); voice.elevenVoice = elevenVoiceID } }
    /// Premio di consolazione dopo la tombola: la seconda cartella che completa tutti i numeri.
    @Published var tombolino: Bool { didSet { d.set(tombolino, forKey: "tmb.tombolino") } }
    /// Trasparenza dell'immagine di sfondo sul maxi schermo (0 = invisibile, 1 = piena).
    @Published var backgroundOpacity: Double { didSet { d.set(backgroundOpacity, forKey: "tmb.bgOpacity") } }
    @Published private(set) var logo: NSImage?
    @Published private(set) var backgroundImage: NSImage?

    // MARK: Partita
    @Published private(set) var gameID = TombolaGame.newID()
    @Published private(set) var cards: [TombolaCard] = []
    @Published private(set) var drawn: [Int] = []
    @Published private(set) var running = false
    @Published private(set) var finished = false
    @Published private(set) var currentPrize: TombolaPrize? = .ambo
    @Published private(set) var winners: [Win] = []
    @Published private(set) var banner: Win?
    @Published private(set) var players: [Int: Player] = [:]
    @Published private(set) var secondsToNext = 0
    private var nextDrawAt: Date?
    private var pausedRemaining: Double?
    private var timer: Timer?

    var current: Int? { drawn.last }
    var drawnSet: Set<Int> { Set(drawn) }

    // MARK: Pagina clienti
    @Published private(set) var serverRunning = false
    @Published private(set) var url = ""
    @Published private(set) var qr: NSImage?
    @Published var serverError: String?
    let port: UInt16 = 8091
    private var listener: NWListener?
    private var token = ""
    private var logoPNG: Data?

    let voice = TombolaVoice()
    let music = TombolaMusic()

    init() {
        intervalSeconds = d.object(forKey: "tmb.interval") as? Double ?? 90
        repeatDelay = d.object(forKey: "tmb.repeat") as? Double ?? 5
        seriesCount = d.object(forKey: "tmb.series") as? Int ?? 4
        familyMode = d.object(forKey: "tmb.family") as? Bool ?? true
        christmas = d.object(forKey: "tmb.xmas") as? Bool ?? true
        pauseAfterWin = d.object(forKey: "tmb.pauseWin") as? Bool ?? true
        venueName = d.string(forKey: "tmb.venue") ?? ""
        voiceID = d.string(forKey: "tmb.voice") ?? ""
        useElevenLabs = d.bool(forKey: "tmb.eleven")
        elevenVoiceID = d.string(forKey: "tmb.elevenVoice") ?? TombolaVoice.defaultElevenVoice
        tombolino = d.object(forKey: "tmb.tombolino") as? Bool ?? true
        backgroundOpacity = d.object(forKey: "tmb.bgOpacity") as? Double ?? 0.35
        voice.voiceID = voiceID
        voice.useEleven = useElevenLabs
        voice.elevenVoice = elevenVoiceID
        voice.onSpeaking = { [weak music] on in music?.duck(on) }
        loadLogo()
        loadBackground()
        newGame()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    static func newID() -> String { String(UUID().uuidString.prefix(6)).lowercased() }

    func smorfia(_ n: Int) -> SmorfiaEntry { Smorfia.entry(n, family: familyMode) }

    // MARK: Comandi

    /// Nuova partita: cartelle nuove e casuali, nessun numero estratto, nessun giocatore.
    func newGame() {
        stopTimerOnly()
        voice.stopAll()
        gameID = TombolaGame.newID()
        cards = TombolaEngine.makeCards(series: seriesCount)
        drawn = []
        players = [:]
        winners = []
        banner = nil
        finished = false
        currentPrize = .ambo
        secondsToNext = Int(intervalSeconds)
    }

    func start() {
        guard !finished, drawn.count < 90 else { return }
        if music.autoStart && !music.isPlaying && !music.tracks.isEmpty { music.play() }
        if !running {
            running = true
            if drawn.isEmpty {
                voice.say("Benvenuti alla tombola napoletana" + (venueName.isEmpty ? "" : " di \(venueName)") + "! Scegliete la vostra cartella. Si comincia!")
                nextDrawAt = Date().addingTimeInterval(min(12, intervalSeconds))
            } else {
                nextDrawAt = Date().addingTimeInterval(pausedRemaining ?? intervalSeconds)
            }
            pausedRemaining = nil
        }
    }

    func pause() {
        guard running else { return }
        pausedRemaining = max(3, nextDrawAt?.timeIntervalSinceNow ?? intervalSeconds)
        stopTimerOnly()
    }

    func toggle() { running ? pause() : start() }

    private func stopTimerOnly() {
        running = false
        nextDrawAt = nil
    }

    private func reschedule() { nextDrawAt = Date().addingTimeInterval(intervalSeconds) }

    /// Estrae subito il prossimo numero (e riparte il conto alla rovescia).
    func drawNow() {
        guard !finished else { return }
        let remaining = Array(Set(1...90).subtracting(drawn))
        guard let n = remaining.randomElement() else { finished = true; stopTimerOnly(); return }
        drawn.append(n)
        announce(n)
        checkWins(number: n)
        if running { reschedule() } else { pausedRemaining = nil }
        secondsToNext = Int(intervalSeconds)
    }

    func repeatLast() {
        guard let n = current else { return }
        let s = smorfia(n)
        voice.say("Ripeto: \(n)! \(Smorfia.spoken(s.napoletano))!")
    }

    func releaseCard(_ id: Int) { players[id] = nil }

    private func tick() {
        guard running, let at = nextDrawAt else { return }
        let left = at.timeIntervalSinceNow
        let s = max(0, Int(left.rounded(.up)))
        if s != secondsToNext { secondsToNext = s }
        if left <= 0 { drawNow() }
    }

    private static let intros = ["Numero", "È uscito il", "Ecco il", "Attenzione, numero", "Signore e signori, il"]

    private func announce(_ n: Int) {
        NSSound(named: "Glass")?.play()
        let s = smorfia(n)
        let intro = TombolaGame.intros.randomElement() ?? "Numero"
        voice.say("\(intro) \(n)!", after: 0.6)
        voice.say("\(n)... \(Smorfia.spoken(s.napoletano))! \(s.italiano).", after: repeatDelay)
    }

    private func checkWins(number n: Int) {
        let set = drawnSet
        while let p = currentPrize {
            // Il tombolino va a una cartella diversa da quelle che hanno già fatto tombola.
            let tombolaCards = Set(winners.filter { $0.prize == .tombola }.flatMap { $0.cards })
            let winning = players.keys.sorted().compactMap { id in cards.first { $0.id == id } }
                .filter { TombolaEngine.achieves($0, prize: p, drawn: set) && !(p == .tombolino && tombolaCards.contains($0.id)) }
            guard !winning.isEmpty else { break }
            let ids = winning.map { $0.id }
            let w = Win(prize: p, cards: ids, names: ids.map { players[$0]?.name ?? "" }, number: n)
            winners.append(w)
            currentPrize = p.next
            let who = ids.map { "cartella \($0)" }.joined(separator: " e ")
            let names = w.names.filter { !$0.isEmpty }.joined(separator: " e ")
            let bravo = names.isEmpty ? "" : ", complimenti \(names)"
            switch p {
            case .tombola:
                if tombolino {
                    voice.say("Tombolaaa! Ha vinto la \(who)\(bravo)! Ma non è finita: adesso si gioca il tombolino!", after: 1)
                } else {
                    voice.say("Tombolaaa! Ha vinto la \(who)\(bravo)! Buone feste a tutti!", after: 1)
                    currentPrize = nil
                    finishGame()
                }
            case .tombolino:
                voice.say("Tombolino! Il premio di consolazione va alla \(who)\(bravo)! Grazie a tutti e buone feste!", after: 1)
                finishGame()
            default:
                voice.say("Abbiamo \(p.withArticle)! Ha vinto la \(who)\(bravo)!", after: 1)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + repeatDelay + 2) { [weak self] in self?.showBanner(w) }
            if pauseAfterWin && !finished { pause() }
            if finished { break }
        }
    }

    private func finishGame() {
        finished = true
        stopTimerOnly()
    }

    private func showBanner(_ w: Win) {
        banner = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            if self?.banner == w { self?.banner = nil }
        }
    }

    // MARK: Logo del locale

    private var logoFile: URL { AppPaths.support.appendingPathComponent("logo-locale.png") }

    func chooseLogo() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "Scegli il logo del locale"
        guard p.runModal() == .OK, let u = p.url, let img = NSImage(contentsOf: u),
              let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: logoFile)
        loadLogo()
    }

    func removeLogo() {
        try? FileManager.default.removeItem(at: logoFile)
        loadLogo()
    }

    private func loadLogo() {
        logoPNG = try? Data(contentsOf: logoFile)
        logo = logoPNG.flatMap { NSImage(data: $0) }
    }

    // MARK: Immagine di sfondo del maxi schermo

    private var backgroundFile: URL { AppPaths.support.appendingPathComponent("sfondo-tombola.jpg") }

    func chooseBackground() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.message = "Scegli l'immagine di sfondo (foto del locale, logo grande, tema natalizio…)"
        guard p.runModal() == .OK, let u = p.url, let img = NSImage(contentsOf: u) else { return }
        // Ridotta a 1920 px e salvata in JPEG: leggera anche su schermi grandi.
        let maxSide: CGFloat = 1920
        let sz = img.size
        let k = min(1, maxSide / max(sz.width, sz.height, 1))
        let out = NSImage(size: NSSize(width: sz.width * k, height: sz.height * k))
        out.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: out.size))
        out.unlockFocus()
        guard let tiff = out.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
        try? jpg.write(to: backgroundFile)
        loadBackground()
    }

    func removeBackground() {
        try? FileManager.default.removeItem(at: backgroundFile)
        loadBackground()
    }

    private func loadBackground() {
        backgroundImage = NSImage(contentsOf: backgroundFile)
    }

    // MARK: Server per i telefoni

    func toggleServer() { serverRunning ? stopServer() : startServer() }

    func startServer() {
        guard !serverRunning else { return }
        token = String(UUID().uuidString.prefix(8)).lowercased()
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in self?.handle(c) }
            l.stateUpdateHandler = { [weak self] st in
                DispatchQueue.main.async {
                    if case .failed(let e) = st { self?.serverError = "Pagina clienti non avviata: \(e.localizedDescription)"; self?.stopServer() }
                }
            }
            l.start(queue: .global(qos: .userInitiated))
            listener = l
        } catch {
            serverError = "Pagina clienti non avviata: \(error.localizedDescription)"
            return
        }
        let ip = WebMonitor.localIPv4() ?? "localhost"
        url = "http://\(ip):\(port)/t/\(token)"
        qr = WebMonitor.qrImage(url)
        serverRunning = true
        serverError = nil
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        serverRunning = false
        url = ""; qr = nil
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .global(qos: .userInitiated))
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self = self, let data = data, let req = String(data: data, encoding: .utf8) else { c.cancel(); return }
            let parts = (req.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            DispatchQueue.main.async {
                let (status, type, body) = self.route(path)
                var head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
                c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
            }
        }
    }

    private static func query(_ q: String) -> [String: String] {
        var out: [String: String] = [:]
        for kv in q.split(separator: "&") {
            let a = kv.split(separator: "=", maxSplits: 1).map(String.init)
            guard a.count == 2 else { continue }
            out[a[0]] = a[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? a[1]
        }
        return out
    }

    private func json(_ o: Any) -> (String, String, Data) {
        ("200 OK", "application/json; charset=utf-8", (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8))
    }

    /// Eseguito sul thread principale.
    private func route(_ path: String) -> (String, String, Data) {
        let comps = path.split(separator: "?", maxSplits: 1)
        let seg = String(comps.first ?? "").split(separator: "/").map(String.init)
        let q = comps.count > 1 ? TombolaGame.query(String(comps[1])) : [:]
        guard seg.count >= 2, seg[0] == "t", seg[1] == token else {
            return ("404 Not Found", "text/plain; charset=utf-8", Data("Link scaduto: inquadra di nuovo il QR sullo schermo".utf8))
        }
        switch seg.count > 2 ? seg[2] : "" {
        case "":
            return ("200 OK", "text/html; charset=utf-8", Data(TombolaWeb.html.utf8))
        case "state":
            return json(stateJSON(clientID: q["cid"] ?? ""))
        case "card":
            guard let id = Int(q["id"] ?? ""), let c = cards.first(where: { $0.id == id }) else { return json(["error": "Cartella non trovata"]) }
            return json(["id": c.id, "rows": c.rows, "owner": players[id]?.name ?? ""])
        case "take":
            let cid = q["cid"] ?? ""
            let name = String((q["name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            guard !cid.isEmpty, let id = Int(q["id"] ?? ""), cards.contains(where: { $0.id == id }) else { return json(["error": "Cartella non valida"]) }
            if let mine = players.first(where: { $0.value.clientID == cid }) { return json(["ok": true, "id": mine.key]) }
            guard players[id] == nil else { return json(["error": "Questa cartella è appena stata presa: scegline un'altra"]) }
            players[id] = Player(name: name, clientID: cid)
            return json(["ok": true, "id": id])
        case "logo":
            if let p = logoPNG { return ("200 OK", "image/png", p) }
            return ("404 Not Found", "text/plain", Data())
        default:
            return ("404 Not Found", "text/plain", Data("Non trovato".utf8))
        }
    }

    private func stateJSON(clientID: String) -> [String: Any] {
        var o: [String: Any] = [
            "game": gameID, "venue": venueName, "logo": logoPNG != nil, "xmas": christmas,
            "drawn": drawn, "running": running, "finished": finished, "next": secondsToNext,
            "prize": currentPrize?.name ?? "", "total": cards.count,
            "free": cards.map { $0.id }.filter { players[$0] == nil },
        ]
        if let n = current {
            let s = smorfia(n)
            o["current"] = n; o["it"] = s.italiano; o["nap"] = s.napoletano; o["sym"] = s.simbolo
        }
        if let mine = players.first(where: { !clientID.isEmpty && $0.value.clientID == clientID }) {
            o["mine"] = mine.key
            o["myName"] = mine.value.name
        }
        o["wins"] = winners.map { ["prize": $0.prize.name, "cards": $0.cards, "names": $0.names] }
        return o
    }
}

/// Voce della tombola: voce di sistema italiana (la migliore femminile installata) oppure ElevenLabs.
/// Le frasi vengono dette una dopo l'altra, con la pausa richiesta prima di ciascuna.
final class TombolaVoice: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let defaultElevenVoice = "21m00Tcm4TlvDq8ikWAM"
    private static let femaleNames = ["federica", "alice", "paola", "emma", "chiara", "silvia", "elsa", "giulia", "sara"]

    var voiceID = ""
    var useEleven = false
    var elevenVoice = defaultElevenVoice
    /// true quando la voce sta per parlare o sta parlando, false quando ha finito tutte le frasi.
    var onSpeaking: ((Bool) -> Void)?
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var queue: [(String, Double)] = []
    private var busy = false
    private var generation = 0

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Voci italiane installate sul Mac: prima le femminili, poi per qualità (Premium, Migliorata).
    static var italianVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("it") }
            .sorted { a, b in
                let fa = isFemale(a), fb = isFemale(b)
                if fa != fb { return fa }
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    static func isFemale(_ v: AVSpeechSynthesisVoice) -> Bool {
        femaleNames.contains { v.name.lowercased().contains($0) }
    }

    static func label(_ v: AVSpeechSynthesisVoice) -> String {
        let q: String
        switch v.quality.rawValue { case 3: q = " · Premium"; case 2: q = " · Migliorata"; default: q = "" }
        return v.name + q + (isFemale(v) ? " (donna)" : "")
    }

    private var systemVoice: AVSpeechSynthesisVoice? {
        if !voiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceID) { return v }
        return TombolaVoice.italianVoices.first ?? AVSpeechSynthesisVoice(language: "it-IT")
    }

    func say(_ text: String, after delay: Double = 0) {
        queue.append((text, delay))
        onSpeaking?(true)
        pump()
    }

    func stopAll() {
        generation += 1
        queue.removeAll()
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        busy = false
        onSpeaking?(false)
    }

    private func pump() {
        guard !busy, !queue.isEmpty else { return }
        busy = true
        let (text, delay) = queue.removeFirst()
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, gen == self.generation else { return }
            let key = Keychain.get(MusicProvider.elevenLabs.rawValue)
            if self.useEleven, !key.isEmpty {
                self.speakEleven(text, key: key, gen: gen)
            } else {
                self.speakSystem(text)
            }
        }
    }

    private func finished() {
        busy = false
        if queue.isEmpty {
            // La musica risale poco dopo l'ultima frase (se nel frattempo non ne arriva un'altra).
            let gen = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self, gen == self.generation, !self.busy, self.queue.isEmpty else { return }
                self.onSpeaking?(false)
            }
        }
        pump()
    }

    private func speakSystem(_ text: String) {
        let u = AVSpeechUtterance(string: text)
        u.voice = systemVoice
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        u.pitchMultiplier = 1.05
        u.volume = 1
        synth.speak(u)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.finished() }
    }

    // MARK: ElevenLabs (voce più naturale, frasi salvate per non ripagarle)

    private var cacheDir: URL {
        let u = AppPaths.support.appendingPathComponent("Voce tombola", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func speakEleven(_ text: String, key: String, gen: Int) {
        let file = cacheDir.appendingPathComponent(StableHash.hex(elevenVoice + "|" + text) + ".mp3")
        if FileManager.default.fileExists(atPath: file.path) { playFile(file); return }
        guard let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(elevenVoice)") else { speakSystem(text); return }
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue(key, forHTTPHeaderField: "xi-api-key")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        let body: [String: Any] = ["text": text, "model_id": "eleven_multilingual_v2",
                                   "voice_settings": ["stability": 0.45, "similarity_boost": 0.8, "style": 0.35]]
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: r) { [weak self] data, resp, _ in
            DispatchQueue.main.async {
                guard let self = self, gen == self.generation else { return }
                if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1000 {
                    try? data.write(to: file)
                    self.playFile(file)
                } else {
                    self.speakSystem(text)   // senza rete o senza credito: voce del Mac
                }
            }
        }.resume()
    }

    private func playFile(_ u: URL) {
        guard let p = try? AVAudioPlayer(contentsOf: u) else { finished(); return }
        p.delegate = self
        player = p
        p.play()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.finished() }
    }
}
