import Foundation
import AppKit

enum SongKind: String, Codable {
    case midi, audio, video
    var icon: String {
        switch self {
        case .midi: return "pianokeys"
        case .audio: return "waveform"
        case .video: return "film"
        }
    }
    static func of(_ url: URL) -> SongKind? {
        switch url.pathExtension.lowercased() {
        case "mid", "midi", "kar", "rmi": return .midi
        case "mp3", "m4a", "wav", "aif", "aiff", "flac", "caf", "aac": return .audio
        case "mp4", "mov", "m4v": return .video
        default: return nil
        }
    }
    static let extensions = ["mid", "midi", "kar", "rmi", "mp3", "m4a", "wav", "aif", "aiff", "flac", "caf", "aac", "mp4", "mov", "m4v"]
}

struct LibraryItem: Identifiable, Hashable, Codable {
    var id: String { path }
    var path: String
    var title: String
    var artist: String
    var kind: SongKind
    var url: URL { URL(fileURLWithPath: path) }
    var hasLyrics: Bool { FileManager.default.fileExists(atPath: SongSidecar.url(for: url).path) || kind == .midi }

    init(url: URL) {
        path = url.path
        kind = SongKind.of(url) ?? .audio
        // "Artista - Titolo" come nei nomi file di Win Live.
        let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
        let parts = name.components(separatedBy: " - ")
        if parts.count >= 2 {
            artist = parts[0].trimmingCharacters(in: .whitespaces)
            title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        } else {
            artist = ""
            title = name
        }
    }
}

/// Archivio dei brani (cartelle scelte dall'utente) e scaletta della serata.
final class Library: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published var search = ""
    @Published var kindFilter: SongKind?
    @Published private(set) var scanning = false
    @Published var setlist: [LibraryItem] = [] { didSet { saveSetlist() } }

    private let settings = AppSettings.shared
    private var cacheURL: URL { AppPaths.support.appendingPathComponent("archivio.json") }

    init() {
        if let d = try? Data(contentsOf: cacheURL), let list = try? JSONDecoder().decode([LibraryItem].self, from: d) { items = list }
        if let paths = UserDefaults.standard.stringArray(forKey: "setlist") {
            setlist = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { LibraryItem(url: URL(fileURLWithPath: $0)) }
        }
        if items.isEmpty && !settings.libraryFolders.isEmpty { rescan() }
    }

    var filtered: [LibraryItem] {
        let q = search.lowercased().trimmingCharacters(in: .whitespaces)
        return items.filter { i in
            (kindFilter == nil || i.kind == kindFilter) &&
            (q.isEmpty || i.title.lowercased().contains(q) || i.artist.lowercased().contains(q))
        }
    }

    func addFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Aggiungi all'archivio"
        p.message = "Scegli le cartelle con basi MIDI/KAR, MP3 e video karaoke"
        if p.runModal() == .OK {
            for u in p.urls where !settings.libraryFolders.contains(u.path) { settings.libraryFolders.append(u.path) }
            rescan()
        }
    }

    func removeFolder(_ path: String) {
        settings.libraryFolders.removeAll { $0 == path }
        rescan()
    }

    func addFiles(_ urls: [URL]) {
        var set = Set(items.map { $0.path })
        for u in urls where SongKind.of(u) != nil && !set.contains(u.path) {
            items.append(LibraryItem(url: u)); set.insert(u.path)
        }
        items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        save()
    }

    func rescan() {
        scanning = true
        let folders = settings.libraryFolders
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [LibraryItem] = []
            let fm = FileManager.default
            for f in folders {
                guard let en = fm.enumerator(at: URL(fileURLWithPath: f), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for case let u as URL in en where SongKind.extensions.contains(u.pathExtension.lowercased()) {
                    found.append(LibraryItem(url: u))
                }
            }
            found.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            DispatchQueue.main.async {
                self.items = found
                self.scanning = false
                self.save()
            }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: cacheURL, options: .atomic) }
    }

    private func saveSetlist() { UserDefaults.standard.set(setlist.map { $0.path }, forKey: "setlist") }

    func enqueue(_ item: LibraryItem) { setlist.append(item) }
}
