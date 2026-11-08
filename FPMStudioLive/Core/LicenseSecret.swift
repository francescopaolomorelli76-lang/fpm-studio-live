// Chiave dell'attivazione. Nel repository resta VUOTA (il codice è pubblico):
// la compilazione su GitHub la sostituisce, mascherata, usando il segreto FPM_ACTIVATION_SECRET del repository.
enum LicenseSecret {
    static let masked: [UInt8] = []
    static var base32: String {
        guard !masked.isEmpty else { return "" }
        let mask = Array("FPM-Studio-Live-2026".utf8)
        return String(decoding: masked.enumerated().map { $0.element ^ mask[$0.offset % mask.count] }, as: UTF8.self)
    }
}
