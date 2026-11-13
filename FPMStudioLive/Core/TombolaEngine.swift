import Foundation

/// Una cartella della tombola: 3 righe × 9 colonne, 5 numeri per riga (15 in tutto).
/// La colonna c contiene i numeri della sua decina (1–9, 10–19, … 80–90). 0 = casella vuota.
struct TombolaCard: Codable, Equatable {
    let id: Int
    let rows: [[Int]]
    var numbers: [Int] { rows.flatMap { $0 }.filter { $0 > 0 } }
}

/// Premi in ordine: ambo, terno, quaterna, cinquina (numeri sulla stessa riga) e tombola (tutti i 15).
enum TombolaPrize: Int, CaseIterable, Codable {
    case ambo = 2, terno = 3, quaterna = 4, cinquina = 5, tombola = 15
    var name: String {
        switch self {
        case .ambo: return "Ambo"
        case .terno: return "Terno"
        case .quaterna: return "Quaterna"
        case .cinquina: return "Cinquina"
        case .tombola: return "Tombola"
        }
    }
    var next: TombolaPrize? {
        let all = TombolaPrize.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}

enum TombolaEngine {
    /// Colonna (decina) di un numero.
    static func column(of n: Int) -> Int { min(8, n / 10) }

    /// Genera `series` serie da 6 cartelle: ogni serie contiene tutti i numeri da 1 a 90 una sola volta,
    /// come il cartellone classico. A ogni partita le cartelle sono nuove e casuali.
    static func makeCards<R: RandomNumberGenerator>(series: Int, using rng: inout R) -> [TombolaCard] {
        var cards: [TombolaCard] = []
        for s in 0..<max(1, series) {
            let set = makeSeries(using: &rng)
            for (i, rows) in set.enumerated() { cards.append(TombolaCard(id: s * 6 + i + 1, rows: rows)) }
        }
        return cards
    }

    static func makeCards(series: Int) -> [TombolaCard] {
        var g = SystemRandomNumberGenerator()
        return makeCards(series: series, using: &g)
    }

    /// Una serie di 6 cartelle con i numeri 1…90.
    static func makeSeries<R: RandomNumberGenerator>(using rng: inout R) -> [[[Int]]] {
        let colNumbers: [[Int]] = (0..<9).map { c in Array((c == 0 ? 1 : c * 10)...(c == 8 ? 90 : c * 10 + 9)) }
        while true {
            // 1) Quanti numeri di ogni colonna va in ogni cartella (da 1 a 3, 15 per cartella).
            guard let counts = distributeCounts(colSizes: colNumbers.map { $0.count }, using: &rng) else { continue }
            // 2) In quali righe stanno (5 per riga).
            var layouts: [[[Bool]]] = []
            var ok = true
            for card in 0..<6 {
                guard let l = rowLayout(counts: counts[card], using: &rng) else { ok = false; break }
                layouts.append(l)
            }
            guard ok else { continue }
            // 3) Distribuisce i numeri, in ordine crescente dall'alto verso il basso.
            var result = [[[Int]]](repeating: [[Int]](repeating: [Int](repeating: 0, count: 9), count: 3), count: 6)
            for c in 0..<9 {
                var pool = colNumbers[c].shuffled(using: &rng)
                for card in 0..<6 {
                    let k = counts[card][c]
                    let mine = pool.prefix(k).sorted()
                    pool.removeFirst(k)
                    var j = 0
                    for r in 0..<3 where layouts[card][r][c] { result[card][r][c] = mine[j]; j += 1 }
                }
            }
            return result
        }
    }

    private static func distributeCounts<R: RandomNumberGenerator>(colSizes: [Int], using rng: inout R) -> [[Int]]? {
        var counts = [[Int]](repeating: [Int](repeating: 1, count: 9), count: 6)
        var cardTotal = [Int](repeating: 9, count: 6)
        // Colonne con più numeri da sistemare per prime.
        for c in (0..<9).sorted(by: { colSizes[$0] > colSizes[$1] }) {
            var extra = colSizes[c] - 6
            while extra > 0 {
                let candidates = (0..<6).filter { cardTotal[$0] < 15 && counts[$0][c] < 3 }
                guard !candidates.isEmpty else { return nil }
                // Preferisce le cartelle più vuote, così si arriva a 15 per tutte.
                let minT = candidates.map { cardTotal[$0] }.min()!
                let best = candidates.filter { cardTotal[$0] <= minT + 1 }
                let card = best.randomElement(using: &rng)!
                counts[card][c] += 1; cardTotal[card] += 1; extra -= 1
            }
        }
        return cardTotal.allSatisfy { $0 == 15 } ? counts : nil
    }

    private static func rowLayout<R: RandomNumberGenerator>(counts: [Int], using rng: inout R) -> [[Bool]]? {
        for _ in 0..<50 {
            var grid = [[Bool]](repeating: [Bool](repeating: false, count: 9), count: 3)
            var cap = [5, 5, 5]
            var ok = true
            for c in (0..<9).shuffled(using: &rng).sorted(by: { counts[$0] > counts[$1] }) {
                let rows = (0..<3).filter { cap[$0] > 0 }.shuffled(using: &rng).sorted { cap[$0] > cap[$1] }
                guard rows.count >= counts[c] else { ok = false; break }
                for r in rows.prefix(counts[c]) { grid[r][c] = true; cap[r] -= 1 }
            }
            if ok && cap == [0, 0, 0] { return grid }
        }
        return nil
    }

    /// Numeri usciti sulla riga migliore (per ambo…cinquina) e in tutta la cartella.
    static func score(_ card: TombolaCard, drawn: Set<Int>) -> (bestRow: Int, total: Int) {
        let perRow = card.rows.map { row in row.filter { $0 > 0 && drawn.contains($0) }.count }
        return (perRow.max() ?? 0, perRow.reduce(0, +))
    }

    static func achieves(_ card: TombolaCard, prize: TombolaPrize, drawn: Set<Int>) -> Bool {
        let s = score(card, drawn: drawn)
        return prize == .tombola ? s.total >= 15 : s.bestRow >= prize.rawValue
    }
}
