import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Sezione "Giochi" per i locali. Il primo gioco è la Tombola napoletana; qui si aggiungeranno gli altri.
struct GamesView: View {
    @ObservedObject var tombola: TombolaGame
    @Environment(\.contentWidth) private var width

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("GIOCHI PER IL LOCALE").font(.system(size: 11, weight: .bold)).tracking(1.4).foregroundColor(Theme.soft)
                Chip(text: "🎄 Tombola napoletana", selected: true) {}
                Text("Altri giochi in arrivo").font(.system(size: 11)).foregroundColor(Theme.soft.opacity(0.7))
            }
            TombolaView(game: tombola)
        }
    }
}

struct TombolaView: View {
    @ObservedObject var game: TombolaGame
    @ObservedObject private var display = TombolaDisplay.shared
    @Environment(\.contentWidth) private var width
    @State private var confirmNew = false
    @State private var elevenKeyMissing = Keychain.get(MusicProvider.elevenLabs.rawValue).isEmpty

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            AdaptiveColumns(width: width, threshold: 980, rightWidth: 360) {
                VStack(alignment: .leading, spacing: 12) {
                    preview
                    playersPanel
                }
            } right: {
                VStack(alignment: .leading, spacing: 12) {
                    clientsPanel
                    musicPanel
                    settingsPanel
                    voicePanel
                }
            }
        }
        .alert("Iniziare una nuova partita?", isPresented: $confirmNew) {
            Button("Nuova partita", role: .destructive) { game.newGame() }
            Button("Annulla", role: .cancel) {}
        } message: {
            Text("Si creano cartelle nuove e casuali: i clienti dovranno sceglierne di nuovo una dal telefono.")
        }
    }

    // MARK: Comandi

    private var controls: some View {
        Panel(title: "Tombola napoletana", icon: "circle.grid.3x3.fill") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button(action: { game.toggle() }) {
                        Label(game.running ? "Pausa" : (game.drawn.isEmpty ? "Avvia la partita" : "Continua"), systemImage: game.running ? "pause.fill" : "play.fill")
                    }.buttonStyle(NeonButtonStyle()).disabled(game.finished)
                    Button(action: { game.drawNow() }) { Label("Estrai ora", systemImage: "sparkles") }
                        .buttonStyle(NeonButtonStyle(prominent: false)).disabled(game.finished)
                    Button(action: { game.repeatLast() }) { Label("Ripeti l'ultimo", systemImage: "speaker.wave.2.fill") }
                        .buttonStyle(NeonButtonStyle(prominent: false)).disabled(game.current == nil)
                    Button(action: { if game.drawn.isEmpty && game.players.isEmpty { game.newGame() } else { confirmNew = true } }) {
                        Label("Nuova partita", systemImage: "arrow.counterclockwise")
                    }.buttonStyle(NeonButtonStyle(prominent: false))
                    Button(action: { display.toggle(game: game) }) {
                        Label(display.isOpen ? "Chiudi maxi schermo" : "Maxi schermo", systemImage: "tv")
                    }.buttonStyle(NeonButtonStyle(prominent: !display.isOpen))
                }.padding(.vertical, 4)
            }
            HStack(spacing: 16) {
                if let n = game.current {
                    let e = game.smorfia(n)
                    Text("\(n)").font(.system(size: 34, weight: .black, design: .rounded)).foregroundStyle(Theme.gradient)
                    Text(e.simbolo).font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.napoletano).font(.system(size: 15, weight: .bold))
                        Text(e.italiano).font(.system(size: 12)).foregroundColor(Theme.soft)
                    }
                } else {
                    Text(game.finished ? "Partita finita" : "Nessun numero estratto").foregroundColor(Theme.soft)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(game.finished ? "Partita finita!" : "In palio: \(game.currentPrize?.name ?? "—")").font(.system(size: 13, weight: .bold))
                    Text(game.running ? "Prossimo numero tra \(formatTime(Double(game.secondsToNext)))" : "In pausa · usciti \(game.drawn.count)/90")
                        .font(.system(size: 12)).foregroundColor(Theme.soft)
                }
            }
            if game.pauseAfterWin, let w = game.winners.last, !game.running, !game.finished {
                Text("🏆 \(w.text). Controlla la cartella del cliente, poi premi Continua.")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.warn)
            }
        }
    }

    // MARK: Anteprima

    private var preview: some View {
        Panel(title: "Anteprima maxi schermo", icon: "tv") {
            TombolaStageView(game: game)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
            Text("Collega la TV o il proiettore e premi \"Maxi schermo\": la tombola si apre a tutto schermo sul secondo monitor.")
                .font(.system(size: 11)).foregroundColor(Theme.soft)
        }
    }

    // MARK: Clienti

    private var clientsPanel: some View {
        Panel(title: "Clienti dal telefono", icon: "qrcode") {
            Toggle("Pagina clienti attiva", isOn: Binding(get: { game.serverRunning }, set: { _ in game.toggleServer() }))
            if let qr = game.qr {
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: qr).interpolation(.none).resizable().frame(width: 130, height: 130)
                        .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("I clienti inquadrano il QR (è anche sul maxi schermo), scelgono una cartella e la vedono a tutto schermo. I numeri si segnano da soli.")
                            .font(.system(size: 11)).foregroundColor(Theme.soft)
                        Text(game.url).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        Button("Copia link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(game.url, forType: .string) }
                            .buttonStyle(NeonButtonStyle(prominent: false))
                    }
                }
            } else {
                Text("Accendi la pagina clienti: telefoni e Mac devono essere sulla stessa rete Wi-Fi.").font(.system(size: 11)).foregroundColor(Theme.soft)
            }
            if let e = game.serverError { Text(e).font(.system(size: 11)).foregroundColor(Theme.warn) }
        }
    }

    private var playersPanel: some View {
        Panel(title: "Cartelle in gioco (\(game.players.count) su \(game.cards.count))", icon: "person.3.fill") {
            if game.players.isEmpty {
                Text("Nessuna cartella scelta. Quando un cliente sceglie la sua, compare qui.").font(.system(size: 12)).foregroundColor(Theme.soft)
            } else {
                let set = game.drawnSet
                ForEach(game.players.keys.sorted(), id: \.self) { id in
                    if let c = game.cards.first(where: { $0.id == id }) {
                        let sc = TombolaEngine.score(c, drawn: set)
                        HStack {
                            Text("n. \(id)").font(.system(size: 13, weight: .bold, design: .monospaced)).frame(width: 52, alignment: .leading)
                            Text(game.players[id]?.name.isEmpty == false ? game.players[id]!.name : "Senza nome").font(.system(size: 13))
                            Spacer()
                            Text("riga migliore \(sc.bestRow)/5 · totale \(sc.total)/15").font(.system(size: 11)).foregroundColor(Theme.soft)
                            Button("Libera") { game.releaseCard(id) }.buttonStyle(.borderless).font(.system(size: 11))
                                .help("Rende di nuovo disponibile la cartella (per esempio se il cliente se ne va)")
                        }
                    }
                }
            }
            if !game.winners.isEmpty {
                Divider().background(Theme.line)
                ForEach(game.winners) { w in
                    Text("🏆 \(w.text) · sul numero \(w.number)").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.warn)
                }
            }
        }
    }

    // MARK: Impostazioni

    // MARK: Musica di sottofondo

    private var musicPanel: some View {
        TombolaMusicPanel(music: game.music)
    }

    private var settingsPanel: some View {
        Panel(title: "Impostazioni", icon: "gearshape") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Un numero ogni \(formatTime(game.intervalSeconds))").font(.system(size: 12, weight: .semibold))
                Slider(value: $game.intervalSeconds, in: 30...300, step: 15)
                Text("Ripetizione in napoletano dopo \(Int(game.repeatDelay)) secondi").font(.system(size: 12, weight: .semibold))
                Slider(value: $game.repeatDelay, in: 2...12, step: 1)
            }
            Picker("Cartelle disponibili", selection: $game.seriesCount) {
                ForEach([1, 2, 3, 4, 5, 6, 8, 10, 15, 20], id: \.self) { n in Text("\(n * 6)").tag(n) }
            }
            Text("Vale dalla prossima \"Nuova partita\". Ogni gruppo di 6 cartelle contiene tutti i numeri da 1 a 90.")
                .font(.system(size: 10)).foregroundColor(Theme.soft)
            TextField("Nome del locale", text: $game.venueName).textFieldStyle(.roundedBorder)
            HStack {
                if let img = game.logo { Image(nsImage: img).resizable().scaledToFit().frame(height: 34) }
                Button(game.logo == nil ? "Scegli il logo del locale…" : "Cambia logo…") { game.chooseLogo() }.buttonStyle(NeonButtonStyle(prominent: false))
                if game.logo != nil { Button("Togli") { game.removeLogo() }.buttonStyle(.borderless) }
            }
            HStack {
                if let img = game.backgroundImage { Image(nsImage: img).resizable().scaledToFill().frame(width: 60, height: 34).clipped().cornerRadius(4) }
                Button(game.backgroundImage == nil ? "Scegli l'immagine di sfondo…" : "Cambia sfondo…") { game.chooseBackground() }.buttonStyle(NeonButtonStyle(prominent: false))
                if game.backgroundImage != nil { Button("Togli") { game.removeBackground() }.buttonStyle(.borderless) }
            }
            if game.backgroundImage != nil {
                Text("Visibilità dello sfondo: \(Int(game.backgroundOpacity * 100))%").font(.system(size: 12, weight: .semibold))
                Slider(value: $game.backgroundOpacity, in: 0.1...0.8)
                Text("Lo sfondo resta dietro al numero e al tabellone: guarda l'anteprima e regola finché tutto si legge bene.")
                    .font(.system(size: 10)).foregroundColor(Theme.soft)
            }
            Toggle("Grafica natalizia (neve e lucine)", isOn: $game.christmas)
            Toggle("Tombolino (premio di consolazione dopo la tombola)", isOn: $game.tombolino)
            Toggle("Pausa dopo ogni vincita (per controllare la cartella)", isOn: $game.pauseAfterWin)
            Toggle("Smorfia per famiglie (detti più delicati)", isOn: $game.familyMode)
        }
    }

    private var voicePanel: some View {
        Panel(title: "Voce", icon: "person.wave.2.fill") {
            let voices = TombolaVoice.italianVoices
            Picker("Voce del Mac", selection: $game.voiceID) {
                Text("Automatica (la migliore voce femminile)").tag("")
                ForEach(voices, id: \.identifier) { v in Text(TombolaVoice.label(v)).tag(v.identifier) }
            }
            Button("Prova la voce") {
                let n = Int.random(in: 1...90), e = game.smorfia(n)
                game.voice.say("Numero \(n)!")
                game.voice.say("\(n)... \(Smorfia.spoken(e.napoletano))! \(e.italiano).", after: 1.5)
            }.buttonStyle(NeonButtonStyle(prominent: false))
            Text("Per una voce più naturale scarica gratis \"Federica\" (Premium): Impostazioni di Sistema › Accessibilità › Contenuti letti ad alta voce › Voce di sistema › Gestisci voci › Italiano. Su Monterey: Preferenze di Sistema › Accessibilità › Contenuto vocale › Voce di sistema › Personalizza.")
                .font(.system(size: 10)).foregroundColor(Theme.soft)
            Divider().background(Theme.line)
            Toggle("Voce ElevenLabs (più umana, richiede la chiave in AI Studio)", isOn: $game.useElevenLabs)
            if game.useElevenLabs {
                TextField("ID della voce ElevenLabs", text: $game.elevenVoiceID).textFieldStyle(.roundedBorder)
                Text(elevenKeyMissing
                     ? "Manca la chiave ElevenLabs: inseriscila in AI Studio. Fino ad allora parla la voce del Mac."
                     : "Ogni frase viene creata una volta sola e salvata: le partite successive non consumano crediti. Senza internet parla la voce del Mac.")
                    .font(.system(size: 10)).foregroundColor(elevenKeyMissing ? Theme.warn : Theme.soft)
            }
        }
        .onAppear { elevenKeyMissing = Keychain.get(MusicProvider.elevenLabs.rawValue).isEmpty }
    }
}

struct TombolaMusicPanel: View {
    @ObservedObject var music: TombolaMusic

    var body: some View {
        Panel(title: "Musica di sottofondo", icon: "music.note.list") {
            HStack(spacing: 8) {
                Button(action: { music.toggle() }) { Label(music.isPlaying ? "Ferma" : "Suona", systemImage: music.isPlaying ? "stop.fill" : "play.fill") }
                    .buttonStyle(NeonButtonStyle()).disabled(music.tracks.isEmpty)
                Button(action: { music.next() }) { Image(systemName: "forward.fill") }
                    .buttonStyle(NeonButtonStyle(prominent: false)).disabled(music.tracks.isEmpty).help("Brano successivo")
                Button("Aggiungi brani o cartelle…") { music.addFiles() }.buttonStyle(NeonButtonStyle(prominent: false))
            }
            if music.isPlaying, !music.currentTitle.isEmpty {
                Text("♪ \(music.currentTitle)").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.cyan).lineLimit(1)
            }
            Text("Volume musica: \(Int(music.volume * 100))%").font(.system(size: 12, weight: .semibold))
            Slider(value: $music.volume, in: 0...1)
            Text("Mentre parla la voce: \(Int(music.duckLevel * 100))% del volume").font(.system(size: 12, weight: .semibold))
            Slider(value: $music.duckLevel, in: 0...0.8)
            Toggle("Ordine casuale", isOn: $music.shuffle)
            Toggle("Parte da sola con la partita", isOn: $music.autoStart)
            if let e = music.error { Text(e).font(.system(size: 11)).foregroundColor(Theme.warn) }
            if music.tracks.isEmpty {
                Text("Aggiungi i tuoi MP3 (per esempio una cartella di canzoni di Natale): suonano uno dopo l'altro per tutta la serata e si abbassano da soli quando la voce dice i numeri.")
                    .font(.system(size: 11)).foregroundColor(Theme.soft)
            } else {
                HStack {
                    Text("\(music.tracks.count) brani in scaletta").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.soft)
                    Spacer()
                    Button("Svuota") { music.clear() }.buttonStyle(.borderless).font(.system(size: 11))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(music.tracks.enumerated()), id: \.offset) { i, u in
                            HStack(spacing: 6) {
                                Image(systemName: music.currentIndex == i && music.isPlaying ? "speaker.wave.2.fill" : "music.note")
                                    .font(.system(size: 10)).foregroundColor(music.currentIndex == i ? Theme.cyan : Theme.soft)
                                Text(u.deletingPathExtension().lastPathComponent).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Button(action: { music.playIndex(i) }) { Image(systemName: "play.circle") }.buttonStyle(.borderless).help("Suona questo")
                                Button(action: { music.remove(at: i) }) { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Togli dalla scaletta")
                            }
                        }
                    }
                }.frame(maxHeight: 160)
            }
            Text("Amazon Music, Spotify e simili non permettono ad altre app di suonare i loro brani. Puoi tenerli aperti sul Mac a volume basso: la voce si sentirà sopra, ma senza abbassamento automatico. Con i tuoi MP3 invece è tutto automatico.")
                .font(.system(size: 10)).foregroundColor(Theme.soft)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let u = url { DispatchQueue.main.async { music.add([u]) } }
                }
            }
            return true
        }
    }
}
