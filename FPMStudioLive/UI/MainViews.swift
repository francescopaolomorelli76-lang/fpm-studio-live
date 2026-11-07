import SwiftUI
import AVFoundation
import CoreAudioKit
import AppKit
import UniformTypeIdentifiers

enum AppSection: String, CaseIterable, Identifiable {
    case karaoke, dj, piano, ai, advanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .karaoke: return "Karaoke"
        case .dj: return "DJ Automix"
        case .piano: return "Piano Studio"
        case .ai: return "AI Studio"
        case .advanced: return "Funzioni avanzate"
        }
    }
    var icon: String {
        switch self {
        case .karaoke: return "music.mic"
        case .dj: return "dial.max"
        case .piano: return "pianokeys"
        case .ai: return "wand.and.stars"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var player: KaraokePlayer
    @EnvironmentObject var library: Library
    @EnvironmentObject var dj: DJController
    @EnvironmentObject var mic: MicEngine
    @EnvironmentObject var piano: PianoStudioModel
    @EnvironmentObject var ai: AIStudioModel
    @EnvironmentObject var sampler: SamplerEngine
    @EnvironmentObject var multitrack: MultitrackPlayer
    @EnvironmentObject var medley: MedleyCreator
    @EnvironmentObject var background: BackgroundMusic
    @EnvironmentObject var web: WebMonitor
    @EnvironmentObject var recorder: VoiceRecorder
    @EnvironmentObject var shortcuts: ShortcutManager
    @State private var section: AppSection = .karaoke
    @State private var showLibrary = true

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 12) {
                if showLibrary {
                    LibraryView(library: library, player: player, dj: dj, piano: piano, ai: ai, section: $section)
                        .frame(width: 290)
                }
                Group {
                    switch section {
                    case .karaoke: KaraokeView(player: player, library: library, mic: mic)
                    case .dj: DJView(dj: dj, library: library)
                    case .piano: PianoStudioView(model: piano)
                    case .ai: AIStudioView(model: ai, player: player, library: library) { section = .karaoke }
                    case .advanced: AdvancedView(player: player, sampler: sampler, multitrack: multitrack, medley: medley,
                                                 background: background, web: web, recorder: recorder, shortcuts: shortcuts)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(12)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundColor(Theme.ink)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1180, minHeight: 760)
        .onAppear {
            player.library = library
            shortcuts.player = player
            shortcuts.install()
            web.player = player
            background.bind(to: player)
            player.onPlaySample = { [weak s = sampler] slot in s?.trigger(slot) }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image("Logo").resizable().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 0) {
                Text("FPM Studio Live").font(.system(size: 18, weight: .heavy)).foregroundStyle(Theme.gradient)
                Text("Karaoke · DJ · Piano · AI").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundColor(Theme.soft)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(AppSection.allCases) { s in
                    Button(action: { section = s }) {
                        Label(s.label, systemImage: s.icon).font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .foregroundColor(section == s ? .white : Theme.soft)
                            .background(Group {
                                if section == s { Capsule().fill(Theme.gradient) } else { Capsule().fill(Theme.bg2) }
                            })
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            Button(action: { withAnimation { showLibrary.toggle() } }) { Image(systemName: "sidebar.left") }
                .buttonStyle(NeonButtonStyle(prominent: false)).help("Mostra/nascondi archivio")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.bg.opacity(0.9))
        .overlay(Rectangle().fill(Theme.line).frame(height: 1), alignment: .bottom)
    }
}

struct LibraryView: View {
    @ObservedObject var library: Library
    @ObservedObject var player: KaraokePlayer
    var dj: DJController
    var piano: PianoStudioModel
    var ai: AIStudioModel
    @Binding var section: AppSection
    @State private var selection: LibraryItem?

    var body: some View {
        Panel(title: "Archivio brani", icon: "books.vertical") {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(Theme.soft)
                TextField("Cerca titolo o artista", text: $library.search).textFieldStyle(.plain)
            }
            .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
            HStack(spacing: 4) {
                Chip(text: "Tutti", selected: library.kindFilter == nil) { library.kindFilter = nil }
                Chip(text: "MIDI", selected: library.kindFilter == .midi) { library.kindFilter = .midi }
                Chip(text: "Audio", selected: library.kindFilter == .audio) { library.kindFilter = .audio }
                Chip(text: "Video", selected: library.kindFilter == .video) { library.kindFilter = .video }
            }
            List(library.filtered, id: \.self, selection: $selection) { it in
                HStack(spacing: 8) {
                    Image(systemName: it.kind.icon).foregroundColor(it == player.item ? Theme.magenta : Theme.cyan).frame(width: 16)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(it.title).font(.system(size: 12, weight: it == player.item ? .bold : .regular)).lineLimit(1)
                        if !it.artist.isEmpty { Text(it.artist).font(.system(size: 10)).foregroundColor(Theme.soft).lineLimit(1) }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { player.load(it, autoplay: true); section = .karaoke }
                .onDrag { NSItemProvider(object: it.url as NSURL) }
                .contextMenu {
                    Button("Canta ora") { player.load(it, autoplay: true); section = .karaoke }
                    Button("Aggiungi alla scaletta") { library.enqueue(it) }
                    Divider()
                    Button("Carica nel deck A") { dj.load(it.url, into: dj.deckA); section = .dj }
                    Button("Carica nel deck B") { dj.load(it.url, into: dj.deckB); section = .dj }
                    Button("Aggiungi alla playlist automix") { dj.playlist.append(it.url) }
                    if it.kind == .midi {
                        Divider()
                        Button("Apri nel Piano Studio") { piano.open(it.url); section = .piano }
                    }
                    Button("Usa come traccia in AI Studio") { ai.setReference(it.url); section = .ai }
                    Divider()
                    Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([it.url]) }
                }
            }
            .frame(minHeight: 200)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        if let u = url { DispatchQueue.main.async { library.addFiles([u]) } }
                    }
                }
                return true
            }
            HStack {
                Text(library.scanning ? "Scansione…" : "\(library.filtered.count) brani").font(.caption).foregroundColor(Theme.soft)
                Spacer()
                Button(action: { library.addFolder() }) { Label("Cartella", systemImage: "folder.badge.plus") }.buttonStyle(NeonButtonStyle(prominent: false))
                Button(action: { library.rescan() }) { Image(systemName: "arrow.clockwise") }.buttonStyle(NeonButtonStyle(prominent: false))
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @EnvironmentObject var player: KaraokePlayer
    @State private var found: [URL] = []
    @StateObject private var sfStore = SoundFontStore()
    @State private var plugins: [AVAudioUnitComponent] = GMSynth.installedInstruments()
    @State private var searching = false

    var body: some View {
        TabView {
            ScrollView { Form {
                Section(header: Text("Suoni professionali: scarica e usa")) {
                    SoundFontStoreView(store: sfStore) { u in
                        settings.soundFontPath = u.path
                        player.reloadSoundFont()
                    }
                }
                Section(header: Text("Strumento professionale (plugin Audio Unit)")) {
                    Text("Per il suono più fedele delle basi MIDI karaoke usa un modulo GM/GS professionale installato sul Mac, per esempio Roland Sound Canvas VA. Compaiono qui tutti gli strumenti Audio Unit installati.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    Picker("Strumento", selection: Binding(get: { settings.synthPluginID }, set: { id in
                        if id.isEmpty { player.reloadSoundFont(); return }
                        let name = plugins.first { GMSynth.identifier($0.audioComponentDescription) == id }.map { $0.manufacturerName + " " + $0.name } ?? id
                        settings.synthPluginID = id
                        settings.synthPluginName = name
                        player.usePlugin(id: id, name: name)
                    })) {
                        Text("Nessuno (usa il SoundFont qui sotto)").tag("")
                        ForEach(plugins, id: \.self) { c in
                            Text("\(c.manufacturerName) — \(c.name)").tag(GMSynth.identifier(c.audioComponentDescription))
                        }
                    }
                    if !settings.synthPluginID.isEmpty {
                        Button("Apri il pannello del plugin") { PluginWindow.show(AudioHub.shared.synth.node, title: settings.synthPluginName) }
                    }
                }
                Section(header: Text("Suoni (SoundFont)")) {
                    Text("Carica il SoundFont .sf2 di Win Live (o un altro .sf2/.dls). Il file resta sul tuo disco e viene letto solo da questa app.")
                        .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text(settings.soundFontName).bold()
                        Spacer()
                        Button("Scegli .sf2…") { chooseSF2() }
                        Button("Suoni inclusi (GeneralUser GS)") { settings.soundFontPath = ""; player.reloadSoundFont() }
                    }
                    HStack {
                        Button(searching ? "Cerco…" : "Cerca SoundFont sul Mac") { search() }.disabled(searching)
                        Spacer()
                    }
                    ForEach(found, id: \.self) { u in
                        HStack {
                            Text(u.lastPathComponent)
                            Text(u.deletingLastPathComponent().path).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            Spacer()
                            Button("Usa") { settings.soundFontPath = u.path; player.reloadSoundFont() }
                        }
                    }
                    HStack {
                        Text("Riverbero sintetizzatore")
                        Slider(value: $settings.synthReverb, in: 0...50)
                    }
                    Toggle("EQ \"professionale\" sulle basi MIDI (bassi pieni, alti chiari)", isOn: $settings.synthEQ)
                }
            } }
            .padding()
            .tabItem { Label("Suoni", systemImage: "speaker.wave.3") }

            Form {
                Picker("Accordi", selection: $settings.notation) { ForEach(ChordNotation.allCases) { Text($0.label).tag($0) } }
                Toggle("Mostra gli accordi sopra il testo", isOn: $settings.showChords)
                HStack { Text("Dimensione testo"); Slider(value: $settings.lyricsFontSize, in: 30...110); Text("\(Int(settings.lyricsFontSize))") }
                Toggle("Passa da solo al brano successivo della scaletta", isOn: $settings.autoAdvance)
                HStack { Text("Pausa tra i brani"); Slider(value: $settings.pauseBetweenSongs, in: 0...20, step: 1); Text("\(Int(settings.pauseBetweenSongs)) s") }
            }
            .padding()
            .tabItem { Label("Karaoke", systemImage: "music.mic") }

            Form {
                HStack { Text("Dissolvenza automix"); Slider(value: $settings.crossfadeSeconds, in: 2...20, step: 1); Text("\(Int(settings.crossfadeSeconds)) s") }
                Section(header: Text("Cartelle dell'archivio")) {
                    ForEach(settings.libraryFolders, id: \.self) { f in Text(f).font(.caption) }
                }
            }
            .padding()
            .tabItem { Label("DJ e archivio", systemImage: "dial.max") }
        }
        .frame(width: 720, height: 620)
    }

    private func chooseSF2() {
        let p = NSOpenPanel()
        p.allowedContentTypes = ["sf2", "sf3", "dls"].compactMap { UTType(filenameExtension: $0) }
        p.message = "Scegli il SoundFont (per esempio quello scaricato con Win Live)"
        if p.runModal() == .OK, let u = p.url {
            settings.soundFontPath = u.path
            player.reloadSoundFont()
        }
    }

    private func search() {
        searching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = AppSettings.findSoundFonts()
            DispatchQueue.main.async { found = r; searching = false }
        }
    }
}

/// Finestra con l'interfaccia del plugin (per scegliere kit, effetti, modalità GS del modulo).
enum PluginWindow {
    static func show(_ unit: AVAudioUnit, title: String) {
        unit.auAudioUnit.requestViewController { vc in
            DispatchQueue.main.async {
                guard let vc = vc else { return }
                let w = NSWindow(contentViewController: vc)
                w.title = title
                w.makeKeyAndOrderFront(nil)
            }
        }
    }
}
