import SwiftUI

/// Forme d'onde du son : un pic par tranche de 10 ms (0…1), calculée par ffmpeg.
final class Onde: @unchecked Sendable {
    static let pas = 0.01
    let pics: [Float]
    init(pics: [Float]) { self.pics = pics }

    /// Lit la première piste son en mono 8 kHz, au fil de l'eau (pas de gros fichier en mémoire).
    /// `partiel` est appelé de temps en temps pour afficher l'onde pendant le calcul des longs fichiers.
    static func calculer(_ url: URL, partiel: @escaping @Sendable (Onde) -> Void) -> Onde? {
        guard let ffmpeg = Binaires.ffmpeg else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-v", "error", "-i", url.path, "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "8000",
                       "-f", "s16le", "-"]
        let tube = Pipe()
        p.standardOutput = tube
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }

        let parTranche = Int(8000 * pas) // 80 échantillons par tranche de 10 ms
        var pics: [Float] = []
        pics.reserveCapacity(1 << 16)
        var crete: Int32 = 0, compte = 0
        var reste: UInt8? = nil
        var prochainPartiel = 6000 // toutes les minutes de son
        let h = tube.fileHandleForReading

        while true {
            let d = h.readData(ofLength: 1 << 16)
            if d.isEmpty { break }
            d.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                var i = 0
                let n = buf.count
                func echantillon(_ lo: UInt8, _ hi: UInt8) {
                    let v = Int32(Int16(bitPattern: UInt16(lo) | UInt16(hi) << 8))
                    let a = v < 0 ? -v : v
                    if a > crete { crete = a }
                    compte += 1
                    if compte == parTranche {
                        pics.append(Float(crete) / 32768)
                        crete = 0; compte = 0
                    }
                }
                if let r = reste, n > 0 { echantillon(r, buf[0]); i = 1; reste = nil }
                while i + 1 < n { echantillon(buf[i], buf[i + 1]); i += 2 }
                if i < n { reste = buf[i] }
            }
            if pics.count >= prochainPartiel {
                partiel(Onde(pics: normaliser(pics)))
                prochainPartiel = pics.count * 2
            }
        }
        if compte > 0 { pics.append(Float(crete) / 32768) }
        p.waitUntilExit()
        return pics.isEmpty ? nil : Onde(pics: normaliser(pics))
    }

    /// Racine carrée (les paroles faibles restent visibles) puis mise à l'échelle sur les pics
    /// habituels (99e centile) : un claquement isolé n'écrase pas le reste du tracé.
    private static func normaliser(_ pics: [Float]) -> [Float] {
        let r = pics.map { $0.squareRoot() }
        let tries = r.sorted()
        let m = tries.isEmpty ? 1 : tries[min(tries.count - 1, Int(Double(tries.count) * 0.99))]
        return m > 0 ? r.map { min(1, $0 / m) } : r
    }

    /// Pic maximal entre deux instants.
    func pic(de a: Double, a b: Double) -> Float {
        let i0 = max(0, Int(a / Self.pas)), i1 = min(pics.count, max(i0 + 1, Int((b / Self.pas).rounded(.up))))
        guard i0 < i1 else { return 0 }
        var m: Float = 0
        for i in i0..<i1 where pics[i] > m { m = pics[i] }
        return m
    }
}

/// Dessin de l'onde pour la portion visible de l'axe. Ne se redessine que si l'onde ou la portion changent.
struct FormeOnde: View, Equatable {
    let onde: Onde?
    let axe: Axe
    let debut: Double
    let longueur: Double
    let sansSon: Bool

    static func == (a: FormeOnde, b: FormeOnde) -> Bool {
        a.onde === b.onde && a.axe == b.axe && a.debut == b.debut && a.longueur == b.longueur && a.sansSon == b.sansSon
    }

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.35))
            if let onde {
                Canvas { ctx, taille in
                    let w = Int(taille.width)
                    guard w > 0, longueur > 0 else { return }
                    let milieu = taille.height / 2
                    var chemin = Path()
                    let largeurPixel = max(longueur / Double(w), Onde.pas)
                    for x in 0..<w {
                        let a = axe.versSource(debut + Double(x) / Double(w) * longueur)
                        let h = CGFloat(onde.pic(de: a, a: a + largeurPixel)) * (taille.height / 2 - 1)
                        chemin.addRect(CGRect(x: CGFloat(x), y: milieu - h, width: 1, height: max(1, h * 2)))
                    }
                    ctx.fill(chemin, with: .color(Color(red: 0.35, green: 0.85, blue: 0.55)))
                }
            } else {
                Text(sansSon ? "Pas de son" : "Analyse du son…")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
