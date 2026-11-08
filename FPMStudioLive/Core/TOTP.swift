import Foundation

/// Codici a 6 cifre che cambiano ogni 30 secondi (TOTP, RFC 6238): gli stessi delle app di autenticazione
/// sull'iPhone (Password di Apple, Google Authenticator, Microsoft Authenticator).
/// SHA-1 e HMAC sono implementati qui per non dipendere da librerie esterne.
enum TOTP {
    static let period: TimeInterval = 30
    static let digits = 6

    /// Codice per un istante.
    static func code(secret: [UInt8], time: Date = Date(), period: TimeInterval = period, digits: Int = digits) -> String {
        var counter = UInt64(floor(time.timeIntervalSince1970 / period)).bigEndian
        let msg = withUnsafeBytes(of: &counter) { Array($0) }
        let h = hmacSHA1(key: secret, message: msg)
        let offset = Int(h[h.count - 1] & 0x0F)
        let bin = (UInt32(h[offset] & 0x7F) << 24) | (UInt32(h[offset + 1]) << 16) | (UInt32(h[offset + 2]) << 8) | UInt32(h[offset + 3])
        var mod: UInt32 = 1
        for _ in 0..<digits { mod *= 10 }
        return String(format: "%0\(digits)u", bin % mod)
    }

    /// Verifica con tolleranza di ±`window` intervalli (per orologi non perfettamente allineati).
    static func verify(_ input: String, secret: [UInt8], time: Date = Date(), window: Int = 1) -> Bool {
        let c = input.filter { $0.isNumber }
        guard c.count == digits, !secret.isEmpty else { return false }
        for k in -window...window where code(secret: secret, time: time.addingTimeInterval(Double(k) * period)) == c { return true }
        return false
    }

    /// Indirizzo da trasformare in QR per l'app dell'iPhone.
    static func otpauthURL(secretBase32: String, account: String, issuer: String) -> String {
        let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        return "otpauth://totp/\(enc(issuer)):\(enc(account))?secret=\(secretBase32)&issuer=\(enc(issuer))&algorithm=SHA1&digits=\(digits)&period=\(Int(period))"
    }

    // MARK: Base32 (RFC 4648)

    static func base32Decode(_ s: String) -> [UInt8] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var map: [Character: UInt8] = [:]
        for (i, c) in alphabet.enumerated() { map[c] = UInt8(i) }
        var out: [UInt8] = [], buffer: UInt32 = 0, bits = 0
        for ch in s.uppercased() where ch != "=" && ch != " " {
            guard let v = map[ch] else { continue }
            buffer = (buffer << 5) | UInt32(v); bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((buffer >> UInt32(bits)) & 0xFF)) }
        }
        return out
    }

    static func base32Encode(_ data: [UInt8]) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = "", buffer: UInt32 = 0, bits = 0
        for b in data {
            buffer = (buffer << 8) | UInt32(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[Int((buffer >> UInt32(bits)) & 31)]) }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return out
    }

    // MARK: SHA-1 e HMAC

    static func sha1(_ message: [UInt8]) -> [UInt8] {
        var h0: UInt32 = 0x67452301, h1: UInt32 = 0xEFCDAB89, h2: UInt32 = 0x98BADCFE, h3: UInt32 = 0x10325476, h4: UInt32 = 0xC3D2E1F0
        var msg = message
        let ml = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((ml >> (UInt64(i) * 8)) & 0xFF)) }
        func rol(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                w[i] = UInt32(msg[chunk + i * 4]) << 24 | UInt32(msg[chunk + i * 4 + 1]) << 16 | UInt32(msg[chunk + i * 4 + 2]) << 8 | UInt32(msg[chunk + i * 4 + 3])
            }
            for i in 16..<80 { w[i] = rol(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let t = rol(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rol(b, 30); b = a; a = t
            }
            h0 = h0 &+ a; h1 = h1 &+ b; h2 = h2 &+ c; h3 = h3 &+ d; h4 = h4 &+ e
        }
        return [h0, h1, h2, h3, h4].flatMap { v in [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) } }
    }

    static func hmacSHA1(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? sha1(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let ipad = k.map { $0 ^ 0x36 }, opad = k.map { $0 ^ 0x5C }
        return sha1(opad + sha1(ipad + message))
    }
}

/// Attivazione all'apertura dell'app: se nella versione è presente la chiave segreta (inserita da GitHub
/// al momento della compilazione), l'app chiede il codice a 6 cifre generato sull'iPhone del titolare.
enum Activation {
    static var secret: [UInt8] { TOTP.base32Decode(LicenseSecret.base32) }
    /// Senza chiave nella build (versione di sviluppo) l'attivazione non viene richiesta.
    static var isRequired: Bool { !LicenseSecret.base32.isEmpty }
    static func check(_ code: String) -> Bool { TOTP.verify(code, secret: secret) }
}
