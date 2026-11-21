import Foundation

/// Montage non destructif : des points de coupe et des plages supprimées (en secondes du fichier source).
/// L'original n'est jamais modifié ; l'export fabrique un nouveau fichier avec les morceaux gardés.
struct Plage: Equatable, Hashable {
    var a: Double
    var b: Double
    var longueur: Double { b - a }
    func contient(_ t: Double) -> Bool { t >= a && t < b }
}

struct Montage: Equatable {
    /// Points de coupe triés, sans doublon.
    var coupes: [Double] = []
    /// Plages supprimées, triées et fusionnées.
    var supprimes: [Plage] = []
    /// Recadrage en coordonnées relatives (0…1) de l'image source, avant rotation. nil = image entière.
    var recadrage: CGRect?
    /// Rotation horaire appliquée après le recadrage : 0, 90, 180 ou 270.
    var rotation = 0

    /// Filtre de couleur (façon iPhone), appliqué à l'aperçu et à l'export.
    var filtre: Filtre = .aucun
    /// Normaliser le volume du son à l'export (ffmpeg loudnorm).
    var normaliser = false

    var aTransfo: Bool { recadrage != nil || rotation != 0 || filtre != .aucun || normaliser }

    static let precision = 0.02 // deux coupes à moins de 20 ms l'une de l'autre = la même

    mutating func couper(a t: Double, duree: Double) {
        guard t > Self.precision, t < duree - Self.precision else { return }
        guard !coupes.contains(where: { abs($0 - t) < Self.precision }) else { return }
        coupes.append(t)
        coupes.sort()
    }

    /// Morceau délimité par les coupes qui contient t.
    func segment(contenant t: Double, duree: Double) -> Plage {
        let avant = coupes.last(where: { $0 <= t + 0.0001 }) ?? 0
        let apres = coupes.first(where: { $0 > t + 0.0001 }) ?? duree
        return Plage(a: avant, b: apres)
    }

    func plageSupprimee(contenant t: Double) -> Plage? {
        supprimes.first { $0.contient(t) }
    }

    func estSupprime(_ p: Plage) -> Bool {
        plageSupprimee(contenant: (p.a + p.b) / 2) != nil
    }

    mutating func supprimer(_ p: Plage) {
        var tout = supprimes + [p]
        tout.sort { $0.a < $1.a }
        var fusion: [Plage] = []
        for q in tout {
            if let d = fusion.last, q.a <= d.b + 0.0001 {
                fusion[fusion.count - 1].b = max(d.b, q.b)
            } else {
                fusion.append(q)
            }
        }
        supprimes = fusion
    }

    mutating func restaurer(_ p: Plage) {
        var res: [Plage] = []
        for q in supprimes {
            if q.b <= p.a || q.a >= p.b { res.append(q); continue }
            if q.a < p.a { res.append(Plage(a: q.a, b: p.a)) }
            if q.b > p.b { res.append(Plage(a: p.b, b: q.b)) }
        }
        supprimes = res.filter { $0.longueur > 0.001 }
    }

    /// Morceaux conservés, dans l'ordre (les miettes de moins de 40 ms sont ignorées).
    func gardees(duree: Double) -> [Plage] {
        var res: [Plage] = []
        var t = 0.0
        for s in supprimes {
            if s.a > t { res.append(Plage(a: t, b: min(s.a, duree))) }
            t = max(t, s.b)
        }
        if t < duree { res.append(Plage(a: t, b: duree)) }
        return res.filter { $0.longueur >= 0.04 }
    }

    func dureeFinale(duree: Double) -> Double {
        gardees(duree: duree).reduce(0) { $0 + $1.longueur }
    }

    var estVide: Bool { supprimes.isEmpty && !aTransfo }
}

/// Axe de la bande de montage. Vue compacte : seuls les morceaux gardés sont alignés bout à bout
/// (les passages supprimés disparaissent) ; sinon l'axe est le temps du fichier.
struct Axe: Equatable {
    let morceaux: [Plage]
    let longueur: Double

    init(montage: Montage, duree: Double, compact: Bool) {
        let g = compact ? montage.gardees(duree: duree) : []
        morceaux = g.isEmpty ? [Plage(a: 0, b: max(duree, 0))] : g
        longueur = morceaux.reduce(0) { $0 + $1.longueur }
    }

    /// Temps du fichier → position sur l'axe (un instant supprimé tombe sur la jonction).
    func versAxe(_ t: Double) -> Double {
        var o = 0.0
        for m in morceaux {
            if t < m.a { return o }
            if t <= m.b { return o + t - m.a }
            o += m.longueur
        }
        return o
    }

    /// Position sur l'axe → temps du fichier (à une jonction : début du morceau suivant).
    func versSource(_ u: Double) -> Double {
        var o = 0.0
        for (i, m) in morceaux.enumerated() {
            if u < o + m.longueur || i == morceaux.count - 1 { return m.a + min(max(0, u - o), m.longueur) }
            o += m.longueur
        }
        return 0
    }

    /// Décalage sur l'axe du début de chaque morceau.
    var departs: [Double] {
        var o = 0.0
        return morceaux.map { m in defer { o += m.longueur }; return o }
    }
}
