import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Clic sull'icona nel Dock: la finestra ridotta (pallino giallo) torna sullo schermo.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        var shown = false
        for w in sender.windows where w.canBecomeMain {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            shown = true
        }
        sender.activate(ignoringOtherApps: true)
        return !shown
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct FPMStudioLiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var player = KaraokePlayer()
    @StateObject private var library = Library()
    @StateObject private var dj = DJController()
    @StateObject private var mic = MicEngine()
    @StateObject private var piano = PianoStudioModel()
    @StateObject private var ai = AIStudioModel()
    @StateObject private var sampler = SamplerEngine()
    @StateObject private var multitrack = MultitrackPlayer()
    @StateObject private var medley = MedleyCreator()
    @StateObject private var background = BackgroundMusic()
    @StateObject private var web = WebMonitor()
    @StateObject private var recorder = VoiceRecorder()
    @StateObject private var shortcuts = ShortcutManager()
    @StateObject private var tombola = TombolaGame()

    var body: some Scene {
        WindowGroup("FPM Studio Live") {
            ContentView()
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(dj)
                .environmentObject(mic)
                .environmentObject(piano)
                .environmentObject(ai)
                .environmentObject(sampler)
                .environmentObject(multitrack)
                .environmentObject(medley)
                .environmentObject(background)
                .environmentObject(web)
                .environmentObject(recorder)
                .environmentObject(shortcuts)
                .environmentObject(tombola)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Apri brano…") { openSong() }.keyboardShortcut("o")
                Button("Aggiungi cartella all'archivio…") { library.addFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Riproduzione") {
                Button(player.isPlaying ? "Pausa" : "Play") { player.togglePlay() }.keyboardShortcut("p")
                Button("Stop") { player.stop() }.keyboardShortcut(".")
                Button("Tono +1") { player.transpose = min(12, player.transpose + 1) }.keyboardShortcut(.upArrow, modifiers: [.command])
                Button("Tono −1") { player.transpose = max(-12, player.transpose - 1) }.keyboardShortcut(.downArrow, modifiers: [.command])
                Button("Avanti 5 s") { player.skip(5) }.keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Indietro 5 s") { player.skip(-5) }.keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("Brano successivo") { player.playNextNow() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Schermo esterno") { ExternalDisplay.shared.toggle(player: player) }.keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Melodia guida on/off") { player.toggleMelody() }.keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
        Settings {
            SettingsView().environmentObject(player)
        }
    }

    private func openSong() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = SongKind.extensions.compactMap { UTType(filenameExtension: $0) }
        guard p.runModal() == .OK else { return }
        library.addFiles(p.urls)
        if let first = p.urls.first { player.load(LibraryItem(url: first), autoplay: false) }
    }
}

