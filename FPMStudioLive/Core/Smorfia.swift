import Foundation

/// La Smorfia napoletana: per ogni numero il significato in italiano, il detto in napoletano e un simbolo.
struct SmorfiaEntry {
    let number: Int
    let italiano: String
    let napoletano: String
    let simbolo: String
}

enum Smorfia {
    /// Numeri con significato "da grandi": con la versione per famiglie si usa il detto alternativo.
    private static let familyVersion: [Int: (String, String, String)] = [
        6: ("Il guardare in basso", "Chella che guarda 'nterra", "👀"),
        16: ("Il fondoschiena", "'O panaro", "🍑"),
        21: ("La donna in costume", "'A femmena 'ncostume", "👙"),
        28: ("Il petto", "'O pietto", "💝"),
        30: ("Le palle del tenente", "'E ppalle d''o tenente", "🎖️"),
        71: ("L'uomo da niente", "L'ommo 'e niente", "🤷"),
    ]

    static func entry(_ n: Int, family: Bool = false) -> SmorfiaEntry {
        guard n >= 1, n <= 90 else { return SmorfiaEntry(number: n, italiano: "", napoletano: "", simbolo: "") }
        if family, let f = familyVersion[n] { return SmorfiaEntry(number: n, italiano: f.0, napoletano: f.1, simbolo: f.2) }
        let e = table[n - 1]
        return SmorfiaEntry(number: n, italiano: e.0, napoletano: e.1, simbolo: e.2)
    }

    /// Testo adatto alla voce sintetica: senza apostrofi napoletani che la voce italiana leggerebbe male.
    static func spoken(_ s: String) -> String {
        s.replacingOccurrences(of: "''", with: "")
         .replacingOccurrences(of: "'", with: "")
         .replacingOccurrences(of: "  ", with: " ")
         .trimmingCharacters(in: .whitespaces)
    }

    static let table: [(String, String, String)] = [
        ("L'Italia", "'A Talia", "🇮🇹"),
        ("La bambina", "'A piccerella", "👧"),
        ("La gatta", "'A jatta", "🐈"),
        ("Il maiale", "'O puorco", "🐖"),
        ("La mano", "'A mano", "✋"),
        ("Quella che guarda a terra", "Chella che guarda 'nterra", "👀"),
        ("Il vaso", "'O vasetto", "🏺"),
        ("La Madonna", "'A Maronna", "🙏"),
        ("La figliolanza", "'A figliata", "👨‍👩‍👧‍👦"),
        ("I fagioli", "'E fasule", "🫘"),
        ("I topolini", "'E suricille", "🐭"),
        ("Il soldato", "'O surdato", "💂"),
        ("Sant'Antonio", "Sant'Antonio", "⛪"),
        ("L'ubriaco", "'O mbriaco", "🍷"),
        ("Il ragazzo", "'O guaglione", "👦"),
        ("Il sedere", "'O culo", "🍑"),
        ("La disgrazia", "'A disgrazia", "⚡"),
        ("Il sangue", "'O sanghe", "🩸"),
        ("La risata", "'A resata", "😂"),
        ("La festa", "'A festa", "🎉"),
        ("La donna nuda", "'A femmena annura", "💃"),
        ("Il pazzo", "'O pazzo", "🤪"),
        ("Lo scemo", "'O scemo", "🤡"),
        ("Le guardie", "'E gguardie", "👮"),
        ("Natale", "Natale", "🎄"),
        ("Annarella", "Nanninella", "👱‍♀️"),
        ("Il vaso da notte", "'O cantero", "🚽"),
        ("Il seno", "'E zzizze", "💝"),
        ("Il padre dei bambini", "'O pate d''e criature", "👨‍👧"),
        ("Le palle del tenente", "'E ppalle d''o tenente", "🎖️"),
        ("Il padrone di casa", "'O padrone 'e casa", "🏠"),
        ("Il capitone", "'O capitone", "🐍"),
        ("Gli anni di Cristo", "Ll'anne 'e Cristo", "✝️"),
        ("La testa", "'A capa", "🗣️"),
        ("L'uccellino", "L'aucelluzzo", "🐦"),
        ("Le nacchere", "'E ccastagnelle", "🪇"),
        ("Il monaco", "'O monaco", "🧑‍🦲"),
        ("Le botte", "'E mmazzate", "🥊"),
        ("La corda al collo", "'A funa 'nganna", "🪢"),
        ("La noia", "'A noia", "🥱"),
        ("Il coltello", "'O curtiello", "🔪"),
        ("Il caffè", "'O ccafè", "☕"),
        ("La donna al balcone", "'Onna pereta fore 'o barcone", "🪟"),
        ("Le carceri", "'E ccancelle", "⛓️"),
        ("Il vino buono", "'O vino bbuono", "🍾"),
        ("I soldi", "'E denare", "💰"),
        ("Il morto", "'O muorto", "⚰️"),
        ("Il morto che parla", "'O muorto che parla", "👻"),
        ("Il pezzo di carne", "'O piezzo 'e carne", "🥩"),
        ("Il pane", "'O ppane", "🍞"),
        ("Il giardino", "'O ciardino", "🌳"),
        ("La mamma", "'A mamma", "👩"),
        ("Il vecchio", "'O viecchio", "👴"),
        ("Il cappello", "'O cappiello", "🎩"),
        ("La musica", "'A museca", "🎶"),
        ("La caduta", "'A caruta", "🤕"),
        ("Il gobbo", "'O scartellato", "🍀"),
        ("Il regalo", "'O paccotto", "🎁"),
        ("I peli", "'E pile", "🧔"),
        ("Si lamenta", "Se lamenta", "😩"),
        ("Il cacciatore", "'O cacciatore", "🏹"),
        ("Il morto ammazzato", "'O muorto acciso", "🗡️"),
        ("La sposa", "'A sposa", "👰"),
        ("La marsina", "'A sciammeria", "🤵"),
        ("Il pianto", "'O chianto", "😢"),
        ("Le due zitelle", "'E ddoje zetelle", "👯‍♀️"),
        ("Il totano nella chitarra", "'O totaro int''a chitarra", "🎸"),
        ("La zuppa cotta", "'A zuppa cotta", "🍲"),
        ("Sottosopra", "Sott'e 'ncoppa", "🙃"),
        ("Il palazzo", "'O palazzo", "🏛️"),
        ("L'uomo senza princìpi", "L'ommo 'e merda", "💩"),
        ("La meraviglia", "'A maraviglia", "🤩"),
        ("L'ospedale", "'O spitale", "🏥"),
        ("La grotta", "'A rotta", "🕳️"),
        ("Pulcinella", "Pullecenella", "🎭"),
        ("La fontana", "'A funtana", "⛲"),
        ("I diavoli", "'E diavule", "😈"),
        ("La bella ragazza", "'A bella figliola", "💁‍♀️"),
        ("Il ladro", "'O mariuolo", "🦹"),
        ("La bocca", "'A vocca", "👄"),
        ("I fiori", "'E sciure", "💐"),
        ("La tavola imbandita", "'A tavula 'mbandita", "🍽️"),
        ("Il maltempo", "'O maletiempo", "⛈️"),
        ("La chiesa", "'A chiesa", "⛪"),
        ("Le anime del purgatorio", "Ll'aneme 'o priatorio", "🕯️"),
        ("La bottega", "'A puteca", "🏪"),
        ("I pidocchi", "'E perucchie", "🐜"),
        ("I caciocavalli", "'E casecavalle", "🧀"),
        ("La vecchia", "'A vecchia", "👵"),
        ("La paura", "'A paura", "😱"),
    ]
}
