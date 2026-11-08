import Foundation
import AVFoundation

/// Generatori musicali AI esterni collegati all'AI Studio.
/// Ogni servizio richiede la chiave personale dell'utente (salvata nel Portachiavi del Mac).
enum MusicProvider: String, CaseIterable, Identifiable, Codable {
    case local, huggingFace, replicate, elevenLabs, suno
    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "FPM locale (bozza MIDI con testo karaoke)"
        case .huggingFace: return "Hugging Face · MusicGen di Meta"
        case .replicate: return "Replicate · MusicGen di Meta"
        case .elevenLabs: return "ElevenLabs Music"
        case .suno: return "Suno (il tuo abbonamento)"
        }
    }
    var cost: String {
        switch self {
        case .local: return "Gratis, offline"
        case .huggingFace: return "Gratis con account (limiti di uso giornalieri)"
        case .replicate: return "A consumo: pochi centesimi a brano"
        case .elevenLabs: return "Piano a pagamento ElevenLabs"
        case .suno: return "Il tuo abbonamento Suno"
        }
    }
    var detail: String {
        switch self {
        case .local: return "Compone con regole musicali: utile come base MIDI e testo sincronizzato, non come brano finito."
        case .huggingFace: return "Musica strumentale generata da intelligenza artificiale a partire dallo stile descritto (brani brevi)."
        case .replicate: return "MusicGen in qualità alta, stereo, fino a 30 secondi. Con \"Ho una traccia\" segue la melodia del tuo brano."
        case .elevenLabs: return "Brani completi, anche cantati con il tuo testo, fino a qualche minuto."
        case .suno: return "Suno non permette ad altre app di creare brani: preparo stile, testo e titolo da incollare in suno.com."
        }
    }
    var tokenPage: URL? {
        switch self {
        case .huggingFace: return URL(string: "https://huggingface.co/settings/tokens")
        case .replicate: return URL(string: "https://replicate.com/account/api-tokens")
        case .elevenLabs: return URL(string: "https://elevenlabs.io/app/settings/api-keys")
        case .suno: return URL(string: "https://suno.com/create")
        case .local: return nil
        }
    }
    var needsToken: Bool { [.huggingFace, .replicate, .elevenLabs].contains(self) }
    var supportsVocals: Bool { self == .elevenLabs || self == .suno || self == .local }
    var maxSeconds: Double {
        switch self {
        case .huggingFace: return 15
        case .replicate: return 30
        case .elevenLabs: return 300
        default: return 600
        }
    }
}

/// Chiavi dei servizi in un file privato dell'app (permessi 600: solo il tuo utente del Mac può leggerlo).
/// Non si usa il Portachiavi perché l'app non è firmata da Apple: ogni aggiornamento chiederebbe la password.
enum Keychain {
    private static var file: URL { AppPaths.support.appendingPathComponent("chiavi-servizi.json") }

    private static func all() -> [String: String] {
        guard let d = try? Data(contentsOf: file), let m = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return m
    }

    static func set(_ value: String, for key: String) {
        var m = all()
        m[key] = value.isEmpty ? nil : value
        guard let d = try? JSONEncoder().encode(m) else { return }
        try? d.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func get(_ key: String) -> String { all()[key] ?? "" }
}

enum MusicProviderError: LocalizedError {
    case missingToken, http(Int, String), noAudio(String), timeout
    var errorDescription: String? {
        switch self {
        case .missingToken: return "Inserisci la chiave del servizio (pulsante \"Ottieni la chiave\")."
        case .http(let c, let m): return "Il servizio ha risposto \(c): \(m)"
        case .noAudio(let m): return "Nessun audio ricevuto: \(m)"
        case .timeout: return "Il servizio non ha finito in tempo: riprova tra poco."
        }
    }
}

/// Chiamate ai servizi. Restituisce il file audio scaricato.
enum MusicGenerator {
    struct Request {
        var provider: MusicProvider
        var prompt: String
        var lyrics: String
        var seconds: Double
        var melodyAudio: URL?      // traccia di riferimento (per MusicGen melody)
        var destFolder: URL
        var title: String
    }

    static func generate(_ r: Request, progress: @escaping (String) -> Void) async throws -> URL {
        let token = Keychain.get(r.provider.rawValue)
        if r.provider.needsToken && token.isEmpty { throw MusicProviderError.missingToken }
        switch r.provider {
        case .huggingFace: return try await huggingFace(r, token: token, progress: progress)
        case .replicate: return try await replicate(r, token: token, progress: progress)
        case .elevenLabs: return try await elevenLabs(r, token: token, progress: progress)
        default: throw MusicProviderError.noAudio("motore non remoto")
        }
    }

    private static func save(_ data: Data, contentType: String?, r: Request) throws -> URL {
        let ext: String
        switch contentType?.lowercased() ?? "" {
        case let t where t.contains("flac"): ext = "flac"
        case let t where t.contains("wav"): ext = "wav"
        case let t where t.contains("ogg"): ext = "ogg"
        default: ext = "mp3"
        }
        let safe = r.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        let u = r.destFolder.appendingPathComponent("\(safe) (\(r.provider == .replicate ? "MusicGen" : r.provider == .huggingFace ? "MusicGen HF" : "ElevenLabs")).\(ext)")
        try data.write(to: u, options: .atomic)
        return u
    }

    private static func check(_ resp: URLResponse, _ data: Data) throws {
        guard let h = resp as? HTTPURLResponse else { return }
        if !(200..<300).contains(h.statusCode) {
            let msg = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw MusicProviderError.http(h.statusCode, msg)
        }
    }

    // Hugging Face: modello facebook/musicgen-small tramite le API di inferenza.
    private static func huggingFace(_ r: Request, token: String, progress: (String) -> Void) async throws -> URL {
        let endpoints = ["https://router.huggingface.co/hf-inference/models/facebook/musicgen-small",
                         "https://api-inference.huggingface.co/models/facebook/musicgen-small"]
        var lastError: Error = MusicProviderError.noAudio("servizio non disponibile")
        for e in endpoints {
            var req = URLRequest(url: URL(string: e)!)
            req.httpMethod = "POST"
            req.timeoutInterval = 300
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("audio/flac, audio/wav, audio/mpeg", forHTTPHeaderField: "Accept")
            let tokens = Int(min(r.seconds, r.provider.maxSeconds) * 50)   // ~50 token al secondo
            req.httpBody = try JSONSerialization.data(withJSONObject: ["inputs": r.prompt, "parameters": ["max_new_tokens": tokens]])
            progress("Hugging Face sta componendo (può servire un minuto)…")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                try check(resp, data)
                let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
                guard type?.contains("audio") == true || data.count > 20_000 else {
                    throw MusicProviderError.noAudio(String(data: data.prefix(300), encoding: .utf8) ?? "")
                }
                return try save(data, contentType: type, r: r)
            } catch { lastError = error }
        }
        throw lastError
    }

    // Replicate: meta/musicgen (ultima versione), con melodia di riferimento facoltativa.
    private static func replicate(_ r: Request, token: String, progress: @escaping (String) -> Void) async throws -> URL {
        func request(_ url: String, method: String = "GET", body: Any? = nil) async throws -> [String: Any] {
            var req = URLRequest(url: URL(string: url)!)
            req.httpMethod = method
            req.timeoutInterval = 120
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let b = body { req.httpBody = try JSONSerialization.data(withJSONObject: b) }
            let (data, resp) = try await URLSession.shared.data(for: req)
            try check(resp, data)
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        progress("Collegamento a Replicate…")
        let model = try await request("https://api.replicate.com/v1/models/meta/musicgen")
        guard let version = (model["latest_version"] as? [String: Any])?["id"] as? String else { throw MusicProviderError.noAudio("versione del modello non trovata") }
        var input: [String: Any] = ["prompt": r.prompt, "duration": Int(min(r.seconds, r.provider.maxSeconds)),
                                    "model_version": r.melodyAudio != nil ? "stereo-melody-large" : "stereo-large",
                                    "output_format": "mp3", "normalization_strategy": "loudness"]
        if let m = r.melodyAudio, let d = try? Data(contentsOf: m), d.count < 4_000_000 {
            input["input_audio"] = "data:audio/mp4;base64," + d.base64EncodedString()
            input["continuation"] = false
        }
        var pred = try await request("https://api.replicate.com/v1/predictions", method: "POST", body: ["version": version, "input": input])
        let get = (pred["urls"] as? [String: Any])?["get"] as? String
        var waited = 0
        while let status = pred["status"] as? String, status != "succeeded" {
            if status == "failed" || status == "canceled" { throw MusicProviderError.noAudio((pred["error"] as? String) ?? status) }
            guard let g = get, waited < 600 else { throw MusicProviderError.timeout }
            progress("Replicate sta componendo… \(waited) s")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            waited += 3
            pred = try await request(g)
        }
        let out = (pred["output"] as? String) ?? (pred["output"] as? [String])?.first
        guard let o = out, let u = URL(string: o) else { throw MusicProviderError.noAudio("nessun file nella risposta") }
        progress("Scarico il brano…")
        let (data, resp) = try await URLSession.shared.data(from: u)
        try check(resp, data)
        return try save(data, contentType: (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), r: r)
    }

    // ElevenLabs Music: brano completo dal prompt (testo incluso se presente).
    private static func elevenLabs(_ r: Request, token: String, progress: (String) -> Void) async throws -> URL {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/music")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue(token, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        var prompt = r.prompt
        if !r.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { prompt += "\nLyrics (Italian):\n" + r.lyrics }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["prompt": prompt, "music_length_ms": Int(min(r.seconds, r.provider.maxSeconds) * 1000)])
        progress("ElevenLabs sta componendo (qualche minuto)…")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp, data)
        return try save(data, contentType: (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), r: r)
    }
}
