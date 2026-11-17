import Foundation

/// Scarica l'audio da un link (YouTube e gli altri siti supportati) con yt-dlp, programma libero e gratuito.
/// yt-dlp non è incluso nell'app: si installa con un clic dal sito ufficiale (GitHub) oppure con Homebrew.
enum LinkDownloader {
    enum Failure: LocalizedError {
        case notInstalled, failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Prima installa yt-dlp con il pulsante \"Installa yt-dlp\"."
            case .failed(let s): return s
            }
        }
    }

    static var toolsFolder: URL {
        let u = AppPaths.support.appendingPathComponent("Strumenti", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static var downloadsFolder: URL {
        let u = AppPaths.support.appendingPathComponent("Scaricati da link", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// yt-dlp installato dall'app o con Homebrew.
    static var executable: URL? {
        let candidates = [toolsFolder.appendingPathComponent("yt-dlp").path, "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Scarica la versione ufficiale per Mac (Intel e Apple Silicon) dal progetto yt-dlp su GitHub.
    static func install() async throws {
        let src = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        let (tmp, resp) = try await URLSession.shared.download(from: src)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.failed("Download di yt-dlp non riuscito") }
        let dest = toolsFolder.appendingPathComponent("yt-dlp")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
    }

    /// Aggiorna yt-dlp (i siti cambiano spesso: se uno smette di funzionare, di solito basta aggiornare).
    static func update() async throws -> String {
        guard let exe = executable else { throw Failure.notInstalled }
        if exe.path.hasPrefix("/opt/homebrew") || exe.path.hasPrefix("/usr/local") {
            return "yt-dlp è installato con Homebrew: aggiornalo dal Terminale con  brew upgrade yt-dlp"
        }
        let (out, code) = try await run(exe, ["-U"]) { _ in }
        return code == 0 ? "yt-dlp aggiornato" : "Aggiornamento non riuscito: " + out.suffix(300)
    }

    /// Scarica la sola traccia audio (M4A/AAC, che il Mac legge senza programmi aggiuntivi).
    static func download(_ link: String, progress: @escaping (Double, String) -> Void) async throws -> URL {
        guard let exe = executable else { throw Failure.notInstalled }
        let dir = downloadsFolder
        let args = ["-f", "bestaudio[ext=m4a]/bestaudio[ext=mp4]/best[ext=mp4]/bestaudio",
                    "--no-playlist", "--newline", "--no-part", "--no-mtime",
                    "-o", dir.path + "/%(title).90B [%(id)s].%(ext)s",
                    "--print", "after_move:filepath",
                    link]
        var path = ""
        let (out, code) = try await run(exe, args) { line in
            if line.hasPrefix("[download]"), let r = line.range(of: #"(\d+(\.\d+)?)%"#, options: .regularExpression),
               let v = Double(line[r].dropLast()) {
                progress(v / 100, "Scarico… \(Int(v))%")
            } else if line.hasPrefix("/"), FileManager.default.fileExists(atPath: line) {
                path = line
            }
        }
        if code != 0 {
            let err = out.split(separator: "\n").filter { $0.contains("ERROR") }.last.map(String.init) ?? String(out.suffix(300))
            throw Failure.failed("Scaricamento non riuscito: " + err.replacingOccurrences(of: "ERROR: ", with: "")
                                 + "\nSe il link è giusto, prova \"Aggiorna yt-dlp\".")
        }
        if path.isEmpty {
            // Ripiego: il file più recente della cartella.
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            path = files.max { a, b in
                ((try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
                ((try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }?.path ?? ""
        }
        guard !path.isEmpty else { throw Failure.failed("File scaricato non trovato") }
        return URL(fileURLWithPath: path)
    }

    /// Esegue un comando leggendo l'output riga per riga.
    private static func run(_ exe: URL, _ args: [String], line: @escaping (String) -> Void) async throws -> (String, Int32) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = exe
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            env["PYTHONIOENCODING"] = "utf-8"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var all = ""
            var pending = ""
            let lock = NSLock()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                lock.lock()
                all += s
                pending += s
                var lines: [String] = []
                while let r = pending.range(of: "\n") {
                    lines.append(String(pending[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
                    pending = String(pending[r.upperBound...])
                }
                lock.unlock()
                lines.forEach(line)
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if let s = String(data: rest, encoding: .utf8) { all += s; pending += s }
                let last = pending.trimmingCharacters(in: .whitespacesAndNewlines)
                lock.unlock()
                for l in last.split(separator: "\n") { line(String(l)) }
                cont.resume(returning: (all, proc.terminationStatus))
            }
            do { try p.run() } catch { cont.resume(throwing: Failure.failed("yt-dlp non si avvia: \(error.localizedDescription)")) }
        }
    }
}

/// Separazione AI di voce, batteria, basso e altro con Demucs su Replicate (chiave in AI Studio).
enum StemSeparator {
    static func separate(_ audio: RenderedAudio, token: String, progress: @escaping (String) -> Void) async throws -> [String: RenderedAudio] {
        func request(_ url: String, method: String = "GET", body: Any? = nil) async throws -> [String: Any] {
            var req = URLRequest(url: URL(string: url)!)
            req.httpMethod = method
            req.timeoutInterval = 300
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let b = body { req.httpBody = try JSONSerialization.data(withJSONObject: b) }
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                throw MusicProviderError.http(h.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
            }
            return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        progress("Preparo il brano da inviare…")
        let mp3 = try MP3Encoder.encode(audio, kbps: 192) { _ in }

        progress("Invio il brano a Replicate…")
        var up = URLRequest(url: URL(string: "https://api.replicate.com/v1/files")!)
        up.httpMethod = "POST"
        up.timeoutInterval = 300
        up.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let boundary = "fpm-\(UUID().uuidString)"
        up.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"content\"; filename=\"brano.mp3\"\r\nContent-Type: audio/mpeg\r\n\r\n".utf8))
        body.append(mp3)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        up.httpBody = body
        let (upData, upResp) = try await URLSession.shared.data(for: up)
        if let h = upResp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw MusicProviderError.http(h.statusCode, String(data: upData.prefix(300), encoding: .utf8) ?? "")
        }
        let upJSON = (try JSONSerialization.jsonObject(with: upData) as? [String: Any]) ?? [:]
        guard let fileURL = (upJSON["urls"] as? [String: Any])?["get"] as? String else { throw MusicProviderError.noAudio("caricamento del brano non riuscito") }

        progress("Avvio la separazione (Demucs)…")
        let model = try await request("https://api.replicate.com/v1/models/ryan5453/demucs")
        guard let version = (model["latest_version"] as? [String: Any])?["id"] as? String else { throw MusicProviderError.noAudio("modello Demucs non trovato") }
        var pred = try await request("https://api.replicate.com/v1/predictions", method: "POST",
                                     body: ["version": version, "input": ["audio": fileURL, "output_format": "mp3"]])
        let get = (pred["urls"] as? [String: Any])?["get"] as? String
        var waited = 0
        while let status = pred["status"] as? String, status != "succeeded" {
            if status == "failed" || status == "canceled" { throw MusicProviderError.noAudio((pred["error"] as? String) ?? status) }
            guard let g = get, waited < 900 else { throw MusicProviderError.timeout }
            progress("L'intelligenza artificiale separa le tracce… \(waited) s")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            waited += 3
            pred = try await request(g)
        }
        // Uscita: { "vocals": url, "drums": url, "bass": url, "other": url } oppure un elenco di indirizzi.
        var links: [String: String] = [:]
        if let dict = pred["output"] as? [String: Any] {
            for (k, v) in dict { if let s = v as? String { links[k] = s } }
        } else if let list = pred["output"] as? [String] {
            for s in list { links[URL(string: s)?.deletingPathExtension().lastPathComponent ?? s] = s }
        }
        guard !links.isEmpty else { throw MusicProviderError.noAudio("nessuna traccia nella risposta") }
        var result: [String: RenderedAudio] = [:]
        for (name, link) in links {
            guard let u = URL(string: link) else { continue }
            progress("Scarico la traccia \(name)…")
            let (data, _) = try await URLSession.shared.data(from: u)
            let tmp = AppPaths.renderCache.appendingPathComponent("stem-\(UUID().uuidString).\(u.pathExtension.isEmpty ? "mp3" : u.pathExtension)")
            try data.write(to: tmp)
            result[name] = try AudioLabDSP.decode(tmp)
            try? FileManager.default.removeItem(at: tmp)
        }
        return result
    }
}
