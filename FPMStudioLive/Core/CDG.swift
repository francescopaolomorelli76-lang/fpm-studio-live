import Foundation

/// Decoder CD+G (karaoke MP3+G): 300 pacchetti al secondo da 24 byte, schermo 300×216, 16 colori.
/// Implementa: Memory Preset, Border Preset, Tile Block (normale e XOR), Scroll Preset/Copy,
/// Load Color Table (low/high). Il riquadro visibile è 288×192.
final class CDGDecoder {
    static let width = 300, height = 216
    static let visibleWidth = 288, visibleHeight = 192
    static let packetsPerSecond = 300.0

    private let data: [UInt8]
    private(set) var pixels = [UInt8](repeating: 0, count: CDGDecoder.width * CDGDecoder.height)
    private(set) var palette = [UInt32](repeating: 0xFF000000, count: 16)   // ARGB
    private(set) var hOffset = 0, vOffset = 0
    private(set) var borderColor = 0
    private var packetIndex = 0
    private(set) var changed = true

    var packetCount: Int { data.count / 24 }
    var duration: Double { Double(packetCount) / CDGDecoder.packetsPerSecond }

    init(data: Data) {
        self.data = [UInt8](data)
    }

    /// Porta lo schermo all'istante t (secondi). Un salto indietro riparte da zero (veloce: ~50k pacchetti per 3 minuti).
    func advance(to t: Double) {
        let target = max(0, min(packetCount, Int(t * CDGDecoder.packetsPerSecond)))
        if target < packetIndex { reset() }
        while packetIndex < target {
            process(packetIndex)
            packetIndex += 1
        }
    }

    func reset() {
        pixels = [UInt8](repeating: 0, count: CDGDecoder.width * CDGDecoder.height)
        palette = [UInt32](repeating: 0xFF000000, count: 16)
        hOffset = 0; vOffset = 0; borderColor = 0
        packetIndex = 0
        changed = true
    }

    private func process(_ i: Int) {
        let o = i * 24
        guard data[o] & 0x3F == 9 else { return }
        let instr = data[o + 1] & 0x3F
        let d = Array(data[(o + 4)..<(o + 20)]).map { $0 & 0x3F }
        switch instr {
        case 1: // Memory preset
            if d[1] & 0x0F == 0 { // solo il primo dei ripetuti
                let c = d[0] & 0x0F
                for k in pixels.indices { pixels[k] = c }
                changed = true
            }
        case 2: // Border preset
            borderColor = Int(d[0] & 0x0F)
            let c = d[0] & 0x0F
            for y in 0..<CDGDecoder.height {
                for x in 0..<CDGDecoder.width where x < 6 || x >= 294 || y < 12 || y >= 204 {
                    pixels[y * CDGDecoder.width + x] = c
                }
            }
            changed = true
        case 6, 38: // Tile block normale / XOR
            let c0 = d[0] & 0x0F, c1 = d[1] & 0x0F
            let row = Int(d[2] & 0x1F), col = Int(d[3] & 0x3F)
            let x0 = col * 6, y0 = row * 12
            guard x0 + 6 <= CDGDecoder.width, y0 + 12 <= CDGDecoder.height else { return }
            for y in 0..<12 {
                let bits = d[4 + y]
                for x in 0..<6 {
                    let on = bits & (0x20 >> UInt8(x)) != 0
                    let idx = (y0 + y) * CDGDecoder.width + x0 + x
                    if instr == 6 { pixels[idx] = on ? c1 : c0 }
                    else { pixels[idx] ^= on ? c1 : c0 }
                }
            }
            changed = true
        case 20, 24: // Scroll preset (riempie) / scroll copy (ruota)
            scroll(color: d[0] & 0x0F, h: d[1], v: d[2], copy: instr == 24)
        case 30, 31: // Load color table low/high
            let base = instr == 30 ? 0 : 8
            for k in 0..<8 {
                let hi = d[k * 2], lo = d[k * 2 + 1]
                let r = UInt32((hi & 0x3C) >> 2) * 17
                let g = UInt32(((hi & 0x03) << 2) | ((lo & 0x30) >> 4)) * 17
                let b = UInt32(lo & 0x0F) * 17
                palette[base + k] = 0xFF000000 | (r << 16) | (g << 8) | b
            }
            changed = true
        default:
            break
        }
    }

    private func scroll(color: UInt8, h: UInt8, v: UInt8, copy: Bool) {
        let hCmd = (h & 0x30) >> 4, vCmd = (v & 0x30) >> 4
        hOffset = Int(h & 0x07)
        vOffset = Int(v & 0x0F)
        let W = CDGDecoder.width, H = CDGDecoder.height
        var dx = 0, dy = 0
        if hCmd == 1 { dx = 6 } else if hCmd == 2 { dx = -6 }
        if vCmd == 1 { dy = 12 } else if vCmd == 2 { dy = -12 }
        guard dx != 0 || dy != 0 else { changed = true; return }
        var out = [UInt8](repeating: color, count: W * H)
        for y in 0..<H {
            for x in 0..<W {
                var sx = x - dx, sy = y - dy
                if copy { sx = (sx + W) % W; sy = (sy + H) % H }
                if sx >= 0 && sx < W && sy >= 0 && sy < H { out[y * W + x] = pixels[sy * W + sx] }
            }
        }
        pixels = out
        changed = true
    }

    /// Immagine visibile (288×192) in RGBA a 8 bit per canale, per CGImage.
    func visibleRGBA() -> [UInt8] {
        let W = CDGDecoder.visibleWidth, H = CDGDecoder.visibleHeight
        var out = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let sx = min(CDGDecoder.width - 1, x + 6 + hOffset), sy = min(CDGDecoder.height - 1, y + 12 + vOffset)
                let c = palette[Int(pixels[sy * CDGDecoder.width + sx])]
                let o = (y * W + x) * 4
                out[o] = UInt8((c >> 16) & 0xFF); out[o + 1] = UInt8((c >> 8) & 0xFF); out[o + 2] = UInt8(c & 0xFF); out[o + 3] = 255
            }
        }
        changed = false
        return out
    }

    /// Quanto dello schermo è "acceso" (diverso dal colore di sfondo): serve a capire se il file contiene grafica.
    var inkRatio: Double {
        guard let bg = pixels.first else { return 0 }
        return Double(pixels.filter { $0 != bg }.count) / Double(pixels.count)
    }
}
