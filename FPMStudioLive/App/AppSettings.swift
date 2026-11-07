import Foundation
import SwiftUI

/// Impostazioni salvate (UserDefaults).
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    /// SoundFont .sf2 (per esempio quello di Win Live) caricato dal disco.
    @Published var soundFontPath: String { didSet { d.set(soundFontPath, forKey: "soundFontPath") } }
    @Published var notation: ChordNotation { didSet { d.set(notation.rawValue, forKey: "notation") } }
    @Published var showChords: Bool { didSet { d.set(showChords, forKey: "showChords") } }
    @Published var lyricsFontSize: Double { didSet { d.set(lyricsFontSize, forKey: "lyricsFontSize") } }
    @Published var autoAdvance: Bool { didSet { d.set(autoAdvance, forKey: "autoAdvance") } }
    @Published var pauseBetweenSongs: Double { didSet { d.set(pauseBetweenSongs, forKey: "pauseBetweenSongs") } }
    @Published var synthReverb: Double { didSet { d.set(synthReverb, forKey: "synthReverb"); AudioHub.shared.synthReverb.wetDryMix = Float(synthReverb) } }
    @Published var synthEQ: Bool { didSet { d.set(synthEQ, forKey: "synthEQ"); AudioHub.configureSynthEQ(AudioHub.shared.synthEQ, enabled: synthEQ) } }
    @Published var crossfadeSeconds: Double { didSet { d.set(crossfadeSeconds, forKey: "crossfadeSeconds") } }
    @Published var libraryFolders: [String] { didSet { d.set(libraryFolders, forKey: "libraryFolders") } }
    /// Show lock: blocca modifiche accidentali durante lo spettacolo.
    @Published var showLock: Bool { didSet { d.set(showLock, forKey: "showLock") } }

    private init() {
        soundFontPath = d.string(forKey: "soundFontPath") ?? ""
        notation = ChordNotation(rawValue: d.string(forKey: "notation") ?? "") ?? .italian
        showChords = d.object(forKey: "showChords") as? Bool ?? true
        lyricsFontSize = d.object(forKey: "lyricsFontSize") as? Double ?? 54
        autoAdvance = d.object(forKey: "autoAdvance") as? Bool ?? true
        pauseBetweenSongs = d.object(forKey: "pauseBetweenSongs") as? Double ?? 4
        synthReverb = d.object(forKey: "synthReverb") as? Double ?? 12
        synthEQ = d.object(forKey: "synthEQ") as? Bool ?? true
        crossfadeSeconds = d.object(forKey: "crossfadeSeconds") as? Double ?? 8
        libraryFolders = d.stringArray(forKey: "libraryFolders") ?? []
        showLock = d.bool(forKey: "showLock")
    }

    var soundFontURL: URL? { soundFontPath.isEmpty ? nil : URL(fileURLWithPath: soundFontPath) }
    var soundFontName: String { soundFontPath.isEmpty ? "Suoni di sistema Apple" : URL(fileURLWithPath: soundFontPath).deletingPathExtension().lastPathComponent }

    /// Cerca automaticamente SoundFont nelle cartelle più comuni (anche quelle copiate da Win Live).
    static func findSoundFonts() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let roots = ["Music", "Documents", "Downloads", "Desktop", "Library/Audio/Sounds/Banks", "Musica", "Documenti"]
            .map { home.appendingPathComponent($0) } + [URL(fileURLWithPath: "/Library/Audio/Sounds/Banks")]
        var found: [URL] = []
        for r in roots {
            guard let en = fm.enumerator(at: r, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            var count = 0
            for case let u as URL in en {
                count += 1
                if count > 40000 { break }
                if ["sf2", "sf3", "dls"].contains(u.pathExtension.lowercased()) { found.append(u) }
            }
        }
        return found
    }
}
