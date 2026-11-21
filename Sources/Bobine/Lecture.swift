import AVFoundation
import AVKit
import SwiftUI

// MARK: - Deux moteurs, une seule interface

@MainActor
protocol MoteurLecture: AnyObject {
    var temps: Double { get }
    var duree: Double { get }
    var enLecture: Bool { get }
    func lire()
    func pause()
    /// Le moteur est en train d'ouvrir ou de charger (après un saut) : sa position n'est pas encore fiable.
    var occupe: Bool { get }
    /// État interne du moteur, pour le journal.
    var diagnostic: String { get }
    func aller(a secondes: Double, precis: Bool)
    func volume(_ v: Double)
    func vitesse(_ r: Float)
    func filtre(_ f: Filtre)
    func fermer()
}

/// Moteur Apple (celui de QuickTime) : formats natifs.
/// Avec un montage, il lit un assemblage virtuel des seuls morceaux gardés (AVMutableComposition : rien
/// n'est copié ni réencodé) : les coupures passent sans le moindre blanc, comme dans le fichier exporté.
/// Vu de l'extérieur, les temps restent ceux du fichier d'origine.
@MainActor
final class MoteurApple: MoteurLecture {
    let player: AVPlayer
    private let asset: AVURLAsset
    private var vit: Float = 1
    /// Morceaux gardés (temps du fichier), nil = fichier entier.
    private var morceaux: [Plage]?
    private var dureeSource = 0.0
    private var filtreCourant: Filtre = .aucun
    init(asset: AVURLAsset) {
        self.asset = asset
        player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }
    var temps: Double { let s = player.currentTime().seconds; return versSource(s.isFinite ? max(0, s) : 0) }
    var duree: Double {
        if morceaux == nil, let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { dureeSource = d }
        return dureeSource
    }
    var enLecture: Bool { player.rate != 0 }
    var occupe: Bool { player.timeControlStatus == .waitingToPlayAtSpecifiedRate }
    var diagnostic: String {
        "rate=\(player.rate) statut=\(player.timeControlStatus.rawValue) attente=\(player.reasonForWaitingToPlay?.rawValue ?? "-")"
    }
    func lire() { player.rate = vit }
    func pause() { player.pause() }
    func aller(a s: Double, precis: Bool) {
        let t = CMTime(seconds: versAssemblage(s), preferredTimescale: 90000)
        let tol = precis ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: tol, toleranceAfter: tol)
    }
    func volume(_ v: Double) { player.volume = Float(min(v, 1)) }
    func vitesse(_ r: Float) { vit = r; if enLecture { player.rate = r } }
    func fermer() { tacheFiltre?.cancel(); tacheMontage?.cancel(); player.pause(); player.replaceCurrentItem(with: nil) }

    // MARK: Assemblage des morceaux gardés

    /// Temps du fichier → temps de l'assemblage (un instant supprimé tombe sur la jonction).
    private func versAssemblage(_ t: Double) -> Double {
        guard let g = morceaux else { return t }
        var o = 0.0
        for m in g {
            if t < m.a { return o }
            if t <= m.b { return o + t - m.a }
            o += m.longueur
        }
        return o
    }
    /// Temps de l'assemblage → temps du fichier.
    private func versSource(_ u: Double) -> Double {
        guard let g = morceaux else { return u }
        var o = 0.0
        for (i, m) in g.enumerated() {
            if u < o + m.longueur || i == g.count - 1 { return m.a + min(max(0, u - o), m.longueur) }
            o += m.longueur
        }
        return u
    }

    private var tacheMontage: Task<Void, Never>?
    /// Remplace ce qui est lu par l'assemblage des morceaux gardés (nil = le fichier entier), même position.
    func garder(_ g: [Plage]?) {
        guard g != morceaux else { return }
        _ = duree   // mémorise la durée du fichier tant qu'on lit encore le fichier entier
        tacheMontage?.cancel()
        tacheMontage = Task { [weak self] in
            guard let self else { return }
            let lecture = self.player.rate, t = self.temps
            let nouvel: AVAsset
            if let g, !g.isEmpty {
                let comp = AVMutableComposition()
                for type in [AVMediaType.video, .audio] {
                    guard let src = try? await self.asset.loadTracks(withMediaType: type).first,
                          let piste = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
                    else { continue }
                    if type == .video, let tr = try? await src.load(.preferredTransform) { piste.preferredTransform = tr }
                    var position = CMTime.zero
                    for m in g {
                        let plage = CMTimeRange(start: CMTime(seconds: m.a, preferredTimescale: 90000),
                                                end: CMTime(seconds: m.b, preferredTimescale: 90000))
                        try? piste.insertTimeRange(plage, of: src, at: position)
                        position = position + plage.duration
                    }
                }
                nouvel = comp
            } else {
                nouvel = self.asset
            }
            if Task.isCancelled { return }
            self.morceaux = (g?.isEmpty ?? true) ? nil : g
            self.player.replaceCurrentItem(with: AVPlayerItem(asset: nouvel))
            self.aller(a: t, precis: true)
            if lecture != 0 { self.player.rate = lecture }
            MoteurVLC.trace("lecture : \(self.morceaux.map { "assemblage de \($0.count) morceaux" } ?? "fichier entier")")
            if self.filtreCourant != .aucun { self.filtre(self.filtreCourant) }
        }
    }

    /// Aperçu du filtre : composition vidéo Core Image (mêmes réglages que l'export).
    private var tacheFiltre: Task<Void, Never>?
    func filtre(_ f: Filtre) {
        tacheFiltre?.cancel()
        filtreCourant = f
        guard let item = player.currentItem else { return }
        if f == .aucun { item.videoComposition = nil; rafraichir(); return }
        let asset = item.asset
        tacheFiltre = Task { [weak self] in
            guard let comp = try? await AVMutableVideoComposition.videoComposition(
                with: asset, applyingCIFiltersWithHandler: { req in
                    req.finish(with: f.appliquer(req.sourceImage), context: Filtre.contexte)
                }) else { return }
            if Task.isCancelled { return }
            item.videoComposition = comp
            MoteurVLC.trace("aperçu : filtre \(f.titre) appliqué (composition Core Image)")
            self?.rafraichir()
        }
    }
    /// À l'arrêt, réaffiche l'image courante avec le nouveau rendu.
    private func rafraichir() {
        if player.rate == 0 { player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero) }
    }
}

/// Moteur VLC : tous les autres formats.
@MainActor
final class MoteurVLCLecture: MoteurLecture {
    private let l: MoteurVLC.Lecteur
    private var dureeConnue: Double = 0
    init?(url: URL, vue: NSView) {
        guard let l = MoteurVLC.Lecteur(url: url, vue: vue) else { return nil }
        self.l = l
    }
    var diagnostic: String { l.diagnostic }
    var occupe: Bool { l.occupe }
    // Tant que VLC « ouvre » le fichier (long pour certains MP4), un saut ou une pause peut le bloquer
    // dans cet état : on retient la dernière demande et on l'applique dès que le fichier est ouvert.
    private var sautEnAttente: Double?
    private var pauseEnAttente = false
    private func appliquerEnAttente() {
        guard !l.ouverture else { return }
        if let t = sautEnAttente { sautEnAttente = nil; l.aller(a: t) }
        if pauseEnAttente { pauseEnAttente = false; l.pause() }
    }
    var temps: Double { appliquerEnAttente(); return sautEnAttente ?? l.temps }
    var duree: Double { let d = l.duree; if d > 0 { dureeConnue = d }; return dureeConnue }
    var enLecture: Bool { l.enLecture }
    func lire() { pauseEnAttente = false; l.lire() }
    func pause() { if l.ouverture { pauseEnAttente = true } else { l.pause() } }
    func aller(a s: Double, precis: Bool) { if l.ouverture { sautEnAttente = s } else { l.aller(a: s) } }
    func volume(_ v: Double) { l.volume(v) }
    func vitesse(_ r: Float) { l.vitesse(r) }
    func filtre(_ f: Filtre) { l.couleur(f == .aucun ? nil : f.vlc) }
    func fermer() { l.fermer() }
    func instantane(_ chemin: String) -> Bool { l.instantane(chemin) }
}

// MARK: - Contrôleur d'une fenêtre : lecture + montage + clavier

@MainActor
final class Controleur: ObservableObject {
    enum Etat { case chargement, pret, erreur(String) }

    let url: URL
    let forcerVLC: Bool
    @Published var etat: Etat = .chargement
    @Published var temps: Double = 0
    @Published var duree: Double = 0
    @Published var enLecture = false
    @Published var volume: Double = 1 { didSet { moteur?.volume(volume) } }
    @Published var vitesse: Float = 1 { didSet { moteur?.vitesse(vitesse) } }
    @Published var montage = Montage() {
        didSet {
            if montage.filtre != oldValue.filtre { moteur?.filtre(montage.filtre) }
            if montage.supprimes != oldValue.supprimes {
                borner()
                (moteur as? MoteurApple)?.garder(montage.supprimes.isEmpty ? nil : montage.gardees(duree: duree))
            }
        }
    }
    @Published var entree: Double?
    @Published var sortie: Double?
    @Published var zoom: Double = 1
    @Published var vignettes: [NSImage] = []
    @Published var message: String?
    @Published var modeRecadrage = false
    @Published var ratio: Ratio = .libre
    /// Taille de l'image telle qu'affichée (pixels, rotation du téléphone déjà appliquée).
    @Published var tailleVideo: CGSize = .zero
    /// Fichier sans image (son seul, ou son avec simple pochette) : on affiche le visuel animé à la place.
    @Published var sonSeul = false
    @Published var onde: Onde?
    @Published var sansSon = false
    /// Début de la portion visible de la bande (en secondes sur l'axe de la bande).
    @Published var debutVue: Double = 0
    /// Vue compacte : les passages supprimés disparaissent de la bande (un repère rouge les remplace).
    @Published var vueCompacte = true { didSet { borner(); suivreTete(centrer: true) } }
    @Published var modeFiltres = false
    /// Outils de montage repliés : il ne reste qu'une barre de lecture (choix mémorisé).
    @Published var outilsReplies = UserDefaults.standard.bool(forKey: "outilsReplies") {
        didSet { UserDefaults.standard.set(outilsReplies, forKey: "outilsReplies") }
    }
    @Published var pleinEcran = false { didSet { activite() } }
    @Published var commandesVisibles = true
    /// Position de la bande dans la fenêtre (repère SwiftUI), pour le défilement au trackpad.
    var cadreBande: CGRect = .zero
    private var masquage: Task<Void, Never>?
    private var moniteurDefilement: Any?
    private var avantGeste: Montage?

    private(set) var moteur: MoteurLecture?
    private(set) var player: AVPlayer?
    let vueVLC = VueNoire()
    var estVLC: Bool { moteur is MoteurVLCLecture }
    var glisse = false
    weak var fenetre: NSWindow?
    /// Montage tel qu'il était au dernier export (pour prévenir avant de fermer).
    var montageExporte = Montage()

    private var annulations: [Montage] = []
    private var retablissements: [Montage] = []
    private var minuterie: Timer?
    private var moniteur: Any?

    init(url: URL, forcerVLC: Bool) {
        self.url = url
        self.forcerVLC = forcerVLC
    }

    var montageNonExporte: Bool { !montage.estVide && montage != montageExporte }

    // MARK: Chargement

    func charger() async {
        guard moteur == nil else { return }
        let source = url
        Task {
            let i = await Task.detached { InfosMedia.lire(source) }.value
            if i.largeur > 0 && i.hauteur > 0 { self.tailleVideo = CGSize(width: i.largeur, height: i.hauteur) }
            self.sonSeul = i.codecVideo == nil && i.codecAudio != nil
        }
        if !forcerVLC {
            let asset = AVURLAsset(url: url)
            let lisible = (try? await asset.load(.isPlayable)) ?? false
            let pistes = (try? await asset.load(.tracks)) ?? []
            if lisible && !pistes.isEmpty {
                MoteurVLC.trace("moteur Apple pour \(url.lastPathComponent)")
                let m = MoteurApple(asset: asset)
                player = m.player
                demarrer(m)
                return
            }
        }
        if MoteurVLC.partage.disponible, let m = MoteurVLCLecture(url: url, vue: vueVLC) {
            MoteurVLC.trace("moteur VLC pour \(url.lastPathComponent)")
            demarrer(m)
        } else {
            MoteurVLC.trace("échec VLC : \(MoteurVLC.partage.erreur ?? "?")")
            etat = .erreur(MoteurVLC.partage.erreur ?? "Format non pris en charge.")
        }
    }

    private func demarrer(_ m: MoteurLecture) {
        moteur = m
        etat = .pret
        m.lire()
        minuterie = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tic() }
        }
        installerClavier()
        Task { await chargerVignettes() }
        chargerOnde()
        autotest()
    }

    // MARK: Lecture

    private func tic() {
        guard let m = moteur else { return }
        enLecture = m.enLecture
        if duree == 0 || m.duree > 0 { duree = m.duree }
        guard !glisse else { return }
        // Un saut demandé n'est pas instantané : tant que le moteur n'y est pas, on garde la cible
        // (sinon l'ancienne position, lue trop tôt, déclencherait un saut de passage supprimé à tort).
        // Certains fichiers (un seul gros bloc de données, ex. son MP3 dans un MP4) font « ouvrir » VLC
        // plusieurs secondes après chaque saut : on attend sans relancer de saut, sinon on tourne en rond.
        if let s = sautEnCours {
            // Arrivé à la cible = fini, même si le moteur se dit encore « occupé » (le moteur Apple peut
            // le rester alors que le son joue déjà).
            let fini = abs(m.temps - s.t) < 0.3 || (!m.occupe && Date() > s.jusqua)
            if fini || Date() > s.jusqua.addingTimeInterval(10) { sautEnCours = nil } else { return }
        }
        temps = m.temps
        // Mesure : délai entre le saut et la reprise effective (le moteur avance au-delà de la cible).
        // Retard = temps écoulé depuis le saut − chemin parcouru par le moteur (≈ silence à la coupure).
        if let (c0, d0) = mesureSaut, Date().timeIntervalSince(d0) > 1.5 {
            let e = Date().timeIntervalSince(d0)
            MoteurVLC.trace(String(format: "retard à la coupure %.2f : %.0f ms", c0, (e * Double(vitesse) - (m.temps - c0)) * 1000))
            mesureSaut = nil
        }
        // Aperçu du montage : on saute les passages supprimés.
        // Marge de 50 ms : un moteur qui atterrit quelques millièmes avant la fin du passage (arrondi en
        // millisecondes de VLC, image ou paquet de son d'Apple) ne doit pas déclencher un nouveau saut,
        // sinon on resaute 25 fois par seconde et la lecture ne repart jamais.
        if enLecture, let p = montage.plageSupprimee(contenant: temps), temps < p.b - 0.05 {
            if p.b >= duree - 0.05 {
                m.pause()
                m.aller(a: p.a, precis: true)
                temps = p.a; sautEnCours = (p.a, Date().addingTimeInterval(1.5))
            } else {
                // Saut précis : un saut « rapide » tombe sur l'image clé d'avant, donc encore dans le
                // passage supprimé, et la lecture bégaierait sur place.
                m.aller(a: p.b + 0.02, precis: true)
                temps = p.b; sautEnCours = (p.b, Date().addingTimeInterval(1.5))
                MoteurVLC.trace(String(format: "saut %.2f → %.2f (%@)", p.a, p.b, m.diagnostic))
                mesureSaut = (p.b + 0.02, Date())
                surveillerSaut(vers: p.b)
            }
        }
        if enLecture { suivreTete(centrer: false) }
    }

    /// Filet de sécurité : si 1,5 s après un saut la lecture n'a pas avancé (moteur bloqué), on relance.
    private var surveillance = false
    private var mesureSaut: (Double, Date)?
    private func surveillerSaut(vers cible: Double, essai: Int = 1) {
        if essai == 1 { guard !surveillance else { return }; surveillance = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.surveillance = essai < 3
            guard let m = self.moteur, self.enLecture || m.occupe else { self.surveillance = false; return }
            let t = m.temps
            guard t < cible + 0.2 else { self.surveillance = false; return }   // ça avance : tout va bien
            MoteurVLC.trace(String(format: "lecture bloquée après le saut vers %.2f (moteur à %.2f, %@) : relance n° %d", cible, t, m.diagnostic, essai))
            m.aller(a: cible + 0.05, precis: false)
            m.lire()
            self.sautEnCours = nil
            if essai < 3 { self.surveillerSaut(vers: cible, essai: essai + 1) }
        }
    }

    func basculer() {
        guard let m = moteur else { return }
        MoteurVLC.trace(String(format: "espace : %@ à %.2f (moteur %.2f, %@)", m.enLecture ? "pause" : "lecture", temps, m.temps, m.diagnostic))
        if m.enLecture { m.pause(); return }
        // Tête dans un passage supprimé ou à la fin : on repart du morceau gardé suivant, sinon du début.
        let t = tempsLisible(temps)
        if abs(t - temps) > 0.001 { aller(a: t) }
        m.lire()
    }

    private var sautEnCours: (t: Double, jusqua: Date)?

    private var premierTempsGarde: Double { montage.gardees(duree: duree).first?.a ?? 0 }
    private var dernierTempsGarde: Double { max(0, (montage.gardees(duree: duree).last?.b ?? duree) - 0.05) }

    /// Instant d'où la lecture peut partir : t lui-même s'il est gardé, sinon le début du morceau
    /// gardé suivant ; après le dernier morceau (ou à la fin du fichier), le début du montage.
    func tempsLisible(_ t: Double) -> Double {
        let g = montage.gardees(duree: duree)
        guard !g.isEmpty else { return 0 }
        if t < duree - 0.1, let m = g.first(where: { t < $0.b - 0.05 }) { return max(t, m.a) }
        return g[0].a
    }

    /// Retour au début du montage (premier instant gardé).
    func allerAuDebut() { aller(a: premierTempsGarde) }

    func aller(a s: Double, precis: Bool = true) {
        let t = max(0, min(s, max(duree - 0.01, 0)))
        moteur?.aller(a: t, precis: precis)
        temps = t
        sautEnCours = (t, Date().addingTimeInterval(1.5))
        if !glisse { suivreTete(centrer: true) }
    }

    func sauter(_ d: Double) { aller(a: temps + d) }

    /// Une image en avant ou en arrière (lecture mise en pause).
    func image(_ sens: Double) {
        moteur?.pause()
        aller(a: temps + sens / 25)
    }

    /// Saute à la coupe (ou au bord de passage supprimé) précédente ou suivante.
    func coupeVoisine(_ sens: Int) {
        var reperes = Set(montage.coupes)
        montage.supprimes.forEach { reperes.insert($0.a); reperes.insert($0.b) }
        if let e = entree { reperes.insert(e) }
        if let s = sortie { reperes.insert(s) }
        reperes.insert(0)
        let tries = reperes.sorted()
        let cible = sens < 0
            ? tries.last(where: { $0 < temps - 0.05 })
            : tries.first(where: { $0 > temps + 0.05 })
        if let c = cible { aller(a: c) }
    }

    // MARK: Montage

    private func modifier(_ action: (inout Montage) -> Void) {
        var m = montage
        action(&m)
        guard m != montage else { return }
        annulations.append(montage)
        if annulations.count > 200 { annulations.removeFirst() }
        retablissements.removeAll()
        montage = m
    }

    func couper() {
        guard duree > 0 else { return }
        modifier { $0.couper(a: temps, duree: duree) }
    }

    func marquerEntree() { entree = temps; if let s = sortie, s <= temps { sortie = nil } }
    func marquerSortie() { sortie = temps; if let e = entree, e >= temps { entree = nil } }
    func effacerMarques() { entree = nil; sortie = nil }

    /// ⌫ : supprime la sélection I–O s'il y en a une, sinon le morceau courant (ou le restaure).
    func supprimer() {
        guard duree > 0 else { return }
        if let e = entree, let s = sortie, s - e > 0.04 {
            let p = Plage(a: e, b: s)
            var essai = montage
            essai.couper(a: e, duree: duree); essai.couper(a: s, duree: duree); essai.supprimer(p)
            guard !essai.gardees(duree: duree).isEmpty else { refus(); return }
            modifier { $0 = essai }
            effacerMarques()
            aller(a: tempsLisible(s))
            return
        }
        let seg = montage.segment(contenant: temps, duree: duree)
        if montage.estSupprime(seg) {
            modifier { $0.restaurer(seg) }
        } else {
            var essai = montage
            essai.supprimer(seg)
            guard !essai.gardees(duree: duree).isEmpty else {
                refus("Coupez d'abord (touche C) pour isoler le passage à supprimer.")
                return
            }
            modifier { $0 = essai }
            if seg.b < duree { aller(a: seg.b) }
        }
    }

    /// Retire la coupe la plus proche de la tête de lecture (si elle est à moins de 0,3 s).
    func retirerCoupe() {
        guard let c = montage.coupes.min(by: { abs($0 - temps) < abs($1 - temps) }),
              abs(c - temps) < 0.3 else { refus(); return }
        modifier { m in
            m.coupes.removeAll { $0 == c }
            // Les deux morceaux de part et d'autre redeviennent un seul : même état que celui de gauche.
            let gauche = m.segment(contenant: max(0, c - 0.01), duree: duree)
            if m.estSupprime(Plage(a: gauche.a, b: c)) { m.supprimer(gauche) } else { m.restaurer(gauche) }
        }
    }

    func toutRestaurer() { modifier { $0 = Montage() }; effacerMarques() }

    func annuler() {
        guard let m = annulations.popLast() else { refus(); return }
        retablissements.append(montage)
        montage = m
    }

    func retablir() {
        guard let m = retablissements.popLast() else { refus(); return }
        annulations.append(montage)
        montage = m
    }

    var peutAnnuler: Bool { !annulations.isEmpty }
    var peutRetablir: Bool { !retablissements.isEmpty }

    private func refus(_ texte: String? = nil) {
        NSSound.beep()
        if let texte {
            message = texte
            Task { try? await Task.sleep(for: .seconds(4)); if self.message == texte { self.message = nil } }
        }
    }

    // MARK: Bande : axe, zoom, défilement

    var axe: Axe { Axe(montage: montage, duree: duree, compact: vueCompacte) }
    /// Zoom maximal : au plus près, 2 secondes sur toute la largeur.
    var zoomMax: Double { max(1, axe.longueur / 2) }
    var longueurVue: Double { axe.longueur / max(zoom, 1) }

    func borner() {
        let l = axe.longueur, v = longueurVue
        debutVue = min(max(0, debutVue), max(0, l - v))
    }

    /// Garde la tête de lecture visible : en lecture, la bande avance d'une page ; sinon on centre.
    func suivreTete(centrer: Bool) {
        let ax = axe, l = longueurVue
        let u = ax.versAxe(temps)
        guard l > 0, u < debutVue || u > debutVue + l * 0.97 else { return }
        debutVue = centrer ? u - l / 2 : u - l * 0.05
        borner()
    }

    func defiler(_ du: Double) { debutVue += du; borner() }

    /// Zoom en gardant fixe le point `ancre` de l'axe (par défaut la tête de lecture, si visible).
    func zoomer(_ z: Double, ancre: Double? = nil) {
        let l0 = longueurVue
        let ut = axe.versAxe(temps)
        let u = ancre ?? ((ut >= debutVue && ut <= debutVue + l0) ? ut : debutVue + l0 / 2)
        let rel = l0 > 0 ? (u - debutVue) / l0 : 0.5
        zoom = min(max(z, 1), zoomMax)
        debutVue = u - rel * longueurVue
        borner()
    }

    /// Sélection faite en glissant sur la forme d'onde (temps du fichier).
    func selectionner(_ a: Double, _ b: Double) {
        let e = min(a, b), s = max(a, b)
        guard s - e > 0.04 else { effacerMarques(); return }
        entree = e; sortie = s
    }

    func restaurerPassage(_ p: Plage) { modifier { $0.restaurer(p) } }

    // MARK: Filtres et son

    func choisirFiltre(_ f: Filtre) { modifier { $0.filtre = f } }
    func basculerFiltres() { terminerRecadrage(); modeFiltres.toggle() }
    func basculerNormaliser() { modifier { $0.normaliser.toggle() } }

    // MARK: Plein écran

    func basculerPleinEcran() { fenetre?.toggleFullScreen(nil) }
    func basculerOutils() { terminerRecadrage(); modeFiltres = false; outilsReplies.toggle() }

    /// Plein écran : les commandes réapparaissent quand la souris bouge, puis s'effacent.
    func activite() {
        masquage?.cancel()
        if !commandesVisibles { commandesVisibles = true }
        guard pleinEcran else { return }
        masquage = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard let self, !Task.isCancelled, self.pleinEcran, self.enLecture else { return }
            self.commandesVisibles = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    // MARK: Export

    func exporter(_ f: FormatExport) {
        terminerRecadrage()
        let garder = montage.supprimes.isEmpty ? nil : montage.gardees(duree: duree)
        moteur?.pause()
        if Export.demander(source: url, format: f, garder: garder, montage: montage.aTransfo ? montage : nil) {
            montageExporte = montage
        }
    }

    /// « Appliquer et rouvrir » : fabrique le fichier monté à côté de l'original (qui n'est pas touché),
    /// puis le rouvre à la place : on repart d'une bande propre.
    func appliquer() {
        guard !montage.estVide else { refus("Rien à appliquer : coupez, recadrez ou choisissez un filtre d'abord."); return }
        terminerRecadrage()
        moteur?.pause()
        let source = url
        let garder = montage.supprimes.isEmpty ? nil : montage.gardees(duree: duree)
        let m = montage
        Task {
            let infos = await Task.detached { InfosMedia.lire(source) }.value
            let format: FormatExport = infos.codecVideo != nil ? .mp4
                : (source.pathExtension.lowercased() == "mp3" ? .mp3 : .m4a)
            let dest = Export.nomLibre(source: source, ext: format.extensionFichier)
            let t = TacheExport(source: source, dest: dest, format: format, garder: garder, montage: m.aTransfo ? m : nil)
            let w = self.fenetre
            t.apresSucces = { [weak self] nouveau in
                self?.montageExporte = m
                Fenetres.partage.remplacer(w, par: nouveau)
            }
            MoteurVLC.trace("appliquer : \(dest.lastPathComponent) (\(format.rawValue))")
            Fenetres.partage.ouvrirExport(t)
        }
    }

    // MARK: Recadrage et rotation

    /// Rapport largeur/hauteur imposé au cadre, dans l'image source (avant rotation). nil = libre.
    var ratioSource: Double? {
        let src = tailleVideo.height > 0 ? Double(tailleVideo.width / tailleVideo.height) : 16.0 / 9
        guard let r = ratio.valeur else { return ratio == .original ? src : nil }
        return montage.rotation % 180 == 90 ? 1 / r : r
    }

    func basculerRecadrage() {
        if modeRecadrage { terminerRecadrage(); return }
        modeRecadrage = true
        modeFiltres = false
        moteur?.pause()
        if montage.recadrage == nil { montage.recadrage = CGRect(x: 0, y: 0, width: 1, height: 1) }
    }

    func terminerRecadrage() {
        guard modeRecadrage else { return }
        modeRecadrage = false
        // Cadre (presque) égal à l'image entière = pas de recadrage.
        if let r = montage.recadrage, r.width > 0.995, r.height > 0.995 { montage.recadrage = nil }
    }

    func choisirRatio(_ r: Ratio) {
        ratio = r
        guard let rs = ratioSource else { return }
        let W = max(Double(tailleVideo.width), 1), H = max(Double(tailleVideo.height), 1)
        var w = W, h = H
        if W / H > rs { w = H * rs } else { h = W / rs }
        let n = CGRect(x: (1 - w / W) / 2, y: (1 - h / H) / 2, width: w / W, height: h / H)
        modifier { $0.recadrage = n }
    }

    /// Pivoter de 90° vers la gauche, comme sur iPhone.
    func pivoter() {
        modifier { $0.rotation = ($0.rotation + 270) % 360 }
        ratio = ratio.inverse
    }


    func reinitialiserCadre() {
        ratio = .libre
        modifier { $0.recadrage = modeRecadrage ? CGRect(x: 0, y: 0, width: 1, height: 1) : nil; $0.rotation = 0 }
    }

    /// Pendant un glissement : on modifie sans empiler d'annulation, puis une seule à la fin.
    func debutGeste() { if avantGeste == nil { avantGeste = montage } }
    func definirCadre(_ r: CGRect) { montage.recadrage = r }
    func finGeste() {
        guard let a = avantGeste else { return }
        avantGeste = nil
        if a != montage {
            annulations.append(a)
            retablissements.removeAll()
        }
    }

    // MARK: Clavier

    private func installerClavier() {
        moniteur = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let f = self.fenetre, e.window === f, f.attachedSheet == nil else { return e }
            if f.firstResponder is NSText { return e }
            return self.touche(e) ? nil : e
        }
        // Trackpad / molette au-dessus de la bande : glisser à deux doigts = défiler, pincer = zoomer.
        moniteurDefilement = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
            guard let self, let f = self.fenetre, e.window === f, let vue = f.contentView,
                  !self.pleinEcran, self.cadreBande.width > 0 else { return e }
            let p = e.locationInWindow
            let pt = CGPoint(x: p.x, y: vue.bounds.height - p.y)
            guard self.cadreBande.contains(pt) else { return e }
            let rel = Double((pt.x - self.cadreBande.minX) / self.cadreBande.width)
            let ancre = self.debutVue + rel * self.longueurVue
            if e.type == .magnify {
                self.zoomer(self.zoom * (1 + Double(e.magnification)), ancre: ancre)
                return nil
            }
            var dx = Double(e.scrollingDeltaX), dy = Double(e.scrollingDeltaY)
            let molette = !e.hasPreciseScrollingDeltas
            if molette { dx *= 8; dy *= 8 }
            // Sens physique (molette vers l'avant = zoom avant), quel que soit le « défilement naturel ».
            let sens: Double = e.isDirectionInvertedFromDevice ? -1 : 1
            if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
                // ⌘ / ⌥ + molette : zoom autour du pointeur.
                self.zoomer(self.zoom * exp(sens * dy * 0.01), ancre: ancre)
            } else if abs(dy) > abs(dx) && !e.modifierFlags.contains(.shift) {
                // Avant / arrière : zoom autour de la tête de lecture (ramenée à l'écran si besoin).
                self.suivreTete(centrer: true)
                self.zoomer(self.zoom * exp(sens * dy * (molette ? 0.02 : 0.01)))
            } else {
                // Gauche / droite (ou ⇧ + molette) : se déplacer.
                let d = abs(dx) >= abs(dy) ? dx : dy
                self.defiler(-d / Double(self.cadreBande.width) * self.longueurVue)
            }
            return nil
        }
    }

    private func touche(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let c = e.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == .command && c == "z" { annuler(); return true }
        if mods == [.command, .shift] && c == "z" { retablir(); return true }
        if mods.contains(.command) || mods.contains(.control) { return false }

        if modeRecadrage, e.keyCode == 36 || e.keyCode == 76 || e.keyCode == 53 { terminerRecadrage(); return true }
        if modeFiltres, e.keyCode == 53 { modeFiltres = false; return true }
        if pleinEcran { activite() }
        if e.keyCode == 53, entree == nil, sortie == nil, pleinEcran { basculerPleinEcran(); return true }
        switch e.keyCode {
        case 49: basculer(); return true                                   // espace
        case 51, 117: supprimer(); return true                             // ⌫ / suppr
        case 123: mods.contains(.shift) ? image(-1) : sauter(mods.contains(.option) ? -1 : -5); return true
        case 124: mods.contains(.shift) ? image(1) : sauter(mods.contains(.option) ? 1 : 5); return true
        case 126: coupeVoisine(-1); return true                            // ↑
        case 125: coupeVoisine(1); return true                             // ↓
        case 115: allerAuDebut(); return true                              // début (↖ ou fn + ←)
        case 119: aller(a: dernierTempsGarde); return true                 // fin (↘ ou fn + →)
        case 53: effacerMarques(); return true                             // échap
        default: break
        }
        switch c {
        case "c", "b": couper()
        case "v": retirerCoupe()
        case "i": marquerEntree()
        case "o": marquerSortie()
        case "x": effacerMarques()
        case "r": basculerRecadrage()
        case "k": moteur?.pause()
        case "j": sauter(-2)
        case "l": sauter(2)
        case "+", "=": zoomer(zoom * 1.6)
        case "-": zoomer(zoom / 1.6)
        case "f": basculerPleinEcran()
        case "t": basculerOutils()
        default: return false
        }
        return true
    }

    // MARK: Forme d'onde

    private func chargerOnde() {
        let source = url
        Task {
            let o = await Task.detached(priority: .utility) {
                Onde.calculer(source) { partielle in
                    Task { @MainActor [weak self] in if self?.onde == nil || (self?.onde?.pics.count ?? 0) < partielle.pics.count { self?.onde = partielle } }
                }
            }.value
            if let o { self.onde = o } else { self.sansSon = true }
            let echantillons = stride(from: 0.5, to: 6, by: 1.0).map { String(format: "%.1fs=%.2f", $0, o?.pic(de: $0 - 0.2, a: $0 + 0.2) ?? -1) }
            MoteurVLC.trace("onde : \(o?.pics.count ?? 0) tranches de 10 ms ; \(echantillons.joined(separator: " "))")
        }
    }

    // MARK: Vignettes (ffmpeg, tous formats)

    private func chargerVignettes() async {
        for _ in 0..<50 where duree <= 0 { try? await Task.sleep(for: .milliseconds(100)) }
        let d = duree
        guard d > 0, let ffmpeg = Binaires.ffmpeg else { return }
        let n = 40
        let source = url
        let images: [NSImage] = await Task.detached(priority: .utility) {
            var res: [NSImage] = []
            for i in 0..<n {
                let t = (Double(i) + 0.5) * d / Double(n)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: ffmpeg)
                p.arguments = ["-v", "error", "-ss", String(format: "%.3f", t), "-i", source.path,
                               "-frames:v", "1", "-vf", "scale=-2:72", "-f", "image2pipe", "-c:v", "mjpeg", "-"]
                let tube = Pipe()
                p.standardOutput = tube
                p.standardError = FileHandle.nullDevice
                guard (try? p.run()) != nil else { return [] }
                let data = tube.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard let img = NSImage(data: data) else { return res.isEmpty ? [] : res }
                res.append(img)
            }
            return res
        }.value
        vignettes = images
    }

    // MARK: Fermeture

    func fermer() {
        minuterie?.invalidate(); minuterie = nil
        if let m = moniteur { NSEvent.removeMonitor(m); moniteur = nil }
        if let m = moniteurDefilement { NSEvent.removeMonitor(m); moniteurDefilement = nil }
        masquage?.cancel()
        moteur?.fermer(); moteur = nil
        player = nil
    }

    // MARK: Auto-test (BOBINE_AUTOTEST=<dossier>)

    private func autotest() {
        guard let d = ProcessInfo.processInfo.environment["BOBINE_AUTOTEST"] else { return }
        // BOBINE_AUTOTEST_FERMER=1 : fermer la fenêtre, puis vérifier que l'accueil revient.
        if ProcessInfo.processInfo.environment["BOBINE_AUTOTEST_FERMER"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.fenetre?.performClose(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    let a = NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == "accueil" }
                    MoteurVLC.trace("AUTOTEST fermeture : accueil affiché = \(a) (attendu true)")
                }
            }
            return
        }
        // BOBINE_AUTOTEST_ETAT=1 : seulement relever l'état du moteur (aucune commande) pendant 10 s.
        if ProcessInfo.processInfo.environment["BOBINE_AUTOTEST_ETAT"] != nil {
            for i in 1...20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.5) { [weak self] in
                    guard let self, let m = self.moteur else { return }
                    MoteurVLC.trace(String(format: "AUTOTEST état %.1f s : t=%.2f lecture=%@ %@", Double(i) * 0.5, m.temps, m.enLecture ? "oui" : "non", m.diagnostic))
                }
            }
            return
        }
        // BOBINE_AUTOTEST_TRAVERSEE=1 : lecture continue à travers deux passages supprimés (relevé toutes les 0,25 s).
        if ProcessInfo.processInfo.environment["BOBINE_AUTOTEST_TRAVERSEE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                // Variante « début » : passage supprimé dès 0 (comme un générique coupé), lecture lancée depuis 0.
                // Valeur : « debut », « 1 », ou des plages à supprimer et un départ, ex. « 0.5-3.3@0 ».
                let v = ProcessInfo.processInfo.environment["BOBINE_AUTOTEST_TRAVERSEE"] ?? "1"
                var plages = v == "debut" ? [(0.0, 2.0), (4.0, 5.0)] : [(2.0, 3.0), (5.0, 6.0)]
                var depart = v == "debut" ? 0.0 : 1.0
                if v.contains("@") {
                    let parts = v.split(separator: "@")
                    depart = Double(parts[1]) ?? 0
                    plages = parts[0].split(separator: ",").compactMap { p in
                        let ab = p.split(separator: "-").compactMap { Double($0) }
                        return ab.count == 2 ? (ab[0], ab[1]) : nil
                    }
                }
                for (a, b) in plages { self.entree = a; self.sortie = b; self.supprimer() }
                self.moteur?.pause(); self.aller(a: depart)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.basculer() }
                for i in 1...48 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * 0.25) {
                        MoteurVLC.trace(String(format: "AUTOTEST traversée %.2f s : t=%.2f lecture=%@ moteur=%.2f occupé=%@", Double(i) * 0.25, self.temps, self.enLecture ? "oui" : "NON", self.moteur?.temps ?? -1, self.moteur?.occupe == true ? "oui" : "non") + " " + ((self.moteur as? MoteurVLCLecture)?.diagnostic ?? ""))
                    }
                }
            }
            return
        }
        // BOBINE_AUTOTEST_LECTURE=1 : reprise de la lecture depuis un passage supprimé (début, milieu, fin).
        if ProcessInfo.processInfo.environment["BOBINE_AUTOTEST_LECTURE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                for (a, b) in [(0.0, 1.0), (2.5, 3.0)] { self.entree = a; self.sortie = b; self.supprimer() }
                self.entree = 6; self.sortie = self.duree; self.supprimer()
                MoteurVLC.trace("AUTOTEST lecture : supprimés \(self.montage.supprimes.map { "\($0.a)-\($0.b)" }), tête après suppression de la fin = \(self.temps) (attendu 1)")
                self.moteur?.pause(); self.aller(a: 7)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.basculer() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    MoteurVLC.trace("AUTOTEST lecture depuis la fin supprimée : t=\(self.temps) en lecture=\(self.enLecture) (attendu entre 1 et 2,5, oui)")
                    self.moteur?.pause(); self.aller(a: 2.7); self.basculer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        MoteurVLC.trace("AUTOTEST lecture depuis le milieu supprimé : t=\(self.temps) en lecture=\(self.enLecture) (attendu > 3,3, oui)")
                        self.moteur?.pause(); self.allerAuDebut()
                        MoteurVLC.trace("AUTOTEST début du montage : t=\(self.temps) (attendu 1)")
                    }
                }
            }
            return
        }
        // BOBINE_AUTOTEST_LARGEUR=<points> : fenêtre réduite à cette largeur (bornée par le minimum), puis image de la fenêtre.
        if let l = ProcessInfo.processInfo.environment["BOBINE_AUTOTEST_LARGEUR"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, let f = self.fenetre, let v = f.contentView else { return }
                var r = f.frame; r.size.width = max(CGFloat(l), f.minSize.width); f.setFrame(r, display: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    MoteurVLC.trace("AUTOTEST fenêtre demandée \(Int(l)) → \(Int(f.frame.width)) points")
                    // Image de la barre de commandes à la largeur réelle de la fenêtre (rendu SwiftUI, thème sombre).
                    let barre = BarreCommandes(c: self).frame(width: v.bounds.width)
                        .background(Color(white: 0.15)).environment(\.colorScheme, .dark)
                    if self.sonSeul {
                        let rs = ImageRenderer(content: VueSon(c: self).frame(width: 800, height: 480)); rs.scale = 1
                        if let cg = rs.cgImage {
                            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                                .write(to: URL(fileURLWithPath: "\(d)/son.png"))
                        }
                    }
                    let r = ImageRenderer(content: barre); r.scale = 2
                    if let cg = r.cgImage {
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                            .write(to: URL(fileURLWithPath: "\(d)/barre-\(Int(f.frame.width)).png"))
                    }
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, let m = self.moteur else { return }
            var ok = ""
            if let v = m as? MoteurVLCLecture {
                ok = " instantane=\(v.instantane("\(d)/vlc-\(self.url.deletingPathExtension().lastPathComponent).png"))"
            }
            MoteurVLC.trace("AUTOTEST \(self.estVLC ? "VLC" : "Apple") \(self.url.lastPathComponent) t=\(m.temps) duree=\(m.duree) lecture=\(m.enLecture)\(ok)")
            // Montage simulé : coupes à 2 s et 4 s, suppression du morceau 2–4 s, lecture depuis 1,5 s.
            self.aller(a: 2); self.couper(); self.aller(a: 4); self.couper()
            self.aller(a: 3); self.supprimer()
            self.aller(a: 1.5); self.moteur?.lire()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MoteurVLC.trace("AUTOTEST montage coupes=\(self.montage.coupes) supprimes=\(self.montage.supprimes.map { "\($0.a)-\($0.b)" }) t=\(self.temps) (attendu > 4) vignettes=\(self.vignettes.count)")
                // Export du montage sans boîte de dialogue.
                let dest = URL(fileURLWithPath: d).appendingPathComponent("montage-\(self.url.deletingPathExtension().lastPathComponent).mp4")
                let t = TacheExport(source: self.url, dest: dest, format: .mp4, garder: self.montage.gardees(duree: self.duree))
                t.lancer()
                // Recadrage 9:16 centré + rotation, exporté à part.
                self.basculerRecadrage()
                self.choisirRatio(.r9_16)
                self.terminerRecadrage()
                MoteurVLC.trace("AUTOTEST taille=\(self.tailleVideo) cadre=\(String(describing: self.montage.recadrage))")
                let dest2 = URL(fileURLWithPath: d).appendingPathComponent("cadre-\(self.url.deletingPathExtension().lastPathComponent).mp4")
                var m2 = self.montage
                m2.rotation = 270
                let t2 = TacheExport(source: self.url, dest: dest2, format: .mp4, garder: self.montage.gardees(duree: self.duree), montage: m2)
                t2.lancer()
                // Vue compacte : 8 s - (2–4 s) = 6 s sur la bande.
                let ax = self.axe
                MoteurVLC.trace("AUTOTEST axe longueur=\(ax.longueur) versAxe(5)=\(ax.versAxe(5)) versSource(2.5)=\(ax.versSource(2.5)) versAxe(3)=\(ax.versAxe(3))")
                self.zoomer(4); self.defiler(100)
                MoteurVLC.trace("AUTOTEST zoom=\(self.zoom) debutVue=\(self.debutVue) longueurVue=\(self.longueurVue) (attendu 4.5 et 1.5)")
                // Filtre + son normalisé, exportés à part.
                var m3 = Montage(); m3.filtre = .mono; m3.normaliser = true
                let dest3 = URL(fileURLWithPath: d).appendingPathComponent("filtre-\(self.url.deletingPathExtension().lastPathComponent).mp4")
                let t3 = TacheExport(source: self.url, dest: dest3, format: .mp4, garder: self.montage.gardees(duree: self.duree), montage: m3)
                t3.lancer()
                self.choisirFiltre(.noir)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if let v = self.moteur as? MoteurVLCLecture {
                        MoteurVLC.trace("AUTOTEST instantané VLC filtré=\(v.instantane("\(d)/vlc-noir.png"))")
                    }
                }
                let source = self.url
                Task.detached { Filtre.comparer(source: source, dossier: d) }
                // « Appliquer et rouvrir » (une seule fois : pas sur le fichier déjà monté).
                if !self.estVLC, !source.lastPathComponent.contains(" montage") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                        self.choisirFiltre(.aucun)
                        self.appliquer()
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    MoteurVLC.trace("AUTOTEST export fini=\(t.fini) echec=\(t.echec ?? "-") ; cadre fini=\(t2.fini) echec=\(t2.echec ?? "-") ; filtre fini=\(t3.fini) echec=\(t3.echec ?? "-")")
                }
            }
        }
    }
}

// MARK: - Vue de la fenêtre

struct VueLecture: View {
    @ObservedObject var c: Controleur

    private var pret: Bool { if case .pret = c.etat { return true } else { return false } }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch c.etat {
                case .chargement:
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                case .pret:
                    ZStack {
                        VueVideo(c: c, rotation: c.montage.rotation, aspect: c.tailleVideo)
                        if c.sonSeul { VueSon(c: c) }
                        VueRecadrage(c: c)
                    }
                case .erreur(let m):
                    Text(m).multilineTextAlignment(.center).padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.black)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if !c.modeRecadrage { c.basculerPleinEcran() } }
            .onTapGesture { if !c.modeRecadrage { c.basculer() } }
            .overlay(alignment: .bottom) {
                if pret && c.pleinEcran && c.commandesVisibles {
                    BarrePleinEcran(c: c).padding(.bottom, 30).transition(.opacity)
                }
            }

            // Plein écran : seulement la vidéo (les outils de montage disparaissent).
            if pret && !c.pleinEcran {
                if c.outilsReplies {
                    BarreLecture(c: c)
                } else {
                    if c.modeFiltres { BarreFiltres(c: c).padding(.top, 10) }
                    BandeMontage(c: c)
                    BarreCommandes(c: c)
                }
            }
        }
        .onContinuousHover { _ in if c.pleinEcran { c.activite() } }
        .animation(.easeInOut(duration: 0.2), value: c.commandesVisibles)
        .frame(minWidth: 760, minHeight: 420)
        .background(AccesFenetre { c.fenetre = $0 })
        .task { await c.charger() }
    }
}

/// Outils de montage repliés : une simple barre de lecture, et la flèche pour les rouvrir.
struct BarreLecture: View {
    @ObservedObject var c: Controleur

    var body: some View {
        HStack(spacing: 12) {
            Button { c.basculer() } label: {
                Image(systemName: c.enLecture ? "pause.fill" : "play.fill").frame(width: 18)
            }.help("Lecture / pause (espace)")
            Text(formatTemps(c.temps)).monospacedDigit().font(.caption)
            Slider(value: Binding(get: { c.temps }, set: { c.glisse = true; c.aller(a: $0, precis: false) }),
                   in: 0...max(c.duree, 0.1),
                   onEditingChanged: { enCours in if !enCours { c.glisse = false; c.aller(a: c.temps) } })
                .controlSize(.small)
            Text("-" + formatTemps(max(0, c.duree - c.temps))).monospacedDigit().font(.caption)
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
            Slider(value: $c.volume, in: 0...1).frame(width: 70).controlSize(.small)
            Button { c.basculerOutils() } label: { Image(systemName: "chevron.up") }
                .help("Afficher les outils de montage (T)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

/// Commandes discrètes en plein écran (apparaissent quand la souris bouge).
struct BarrePleinEcran: View {
    @ObservedObject var c: Controleur

    var body: some View {
        HStack(spacing: 14) {
            Button { c.sauter(-5) } label: { Image(systemName: "gobackward.5") }
            Button { c.basculer() } label: {
                Image(systemName: c.enLecture ? "pause.fill" : "play.fill").font(.title2).frame(width: 26)
            }
            Button { c.sauter(5) } label: { Image(systemName: "goforward.5") }
            Text(formatTemps(c.temps)).monospacedDigit()
            Slider(value: Binding(get: { c.temps }, set: { c.glisse = true; c.aller(a: $0, precis: false) }),
                   in: 0...max(c.duree, 0.1),
                   onEditingChanged: { enCours in if !enCours { c.glisse = false; c.aller(a: c.temps) } })
            Text("-" + formatTemps(max(0, c.duree - c.temps))).monospacedDigit()
            Button { c.basculerPleinEcran() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .help("Quitter le plein écran (Échap ou F)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: 760)
        .padding(.horizontal, 40)
    }
}

/// Récupère la NSWindow qui contient la vue (pour le clavier).
struct AccesFenetre: NSViewRepresentable {
    let rappel: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { rappel(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Image vidéo (moteur Apple ou VLC) dans un conteneur qui applique l'aperçu de la rotation.
struct VueVideo: NSViewRepresentable {
    let c: Controleur
    let rotation: Int
    let aspect: CGSize

    func makeNSView(context: Context) -> ConteneurTransforme {
        let enfant: NSView
        if let p = c.player {
            let v = AVPlayerView()
            v.player = p
            v.controlsStyle = .none // nos propres commandes (montage)
            enfant = v
        } else {
            enfant = c.vueVLC
        }
        return ConteneurTransforme(enfant: enfant)
    }

    func updateNSView(_ v: ConteneurTransforme, context: Context) {
        v.rotation = rotation
        v.aspect = aspect
        v.needsLayout = true
    }
}

/// Facteur d'agrandissement pour qu'une image tournée de 90° tienne dans la zone.
func echelleRotation(zone: CGSize, aspect: CGSize, rotation: Int) -> CGFloat {
    guard rotation % 180 == 90, zone.width > 0, zone.height > 0 else { return 1 }
    let a = aspect.width > 0 && aspect.height > 0 ? aspect : CGSize(width: 16, height: 9)
    let k = min(zone.width / a.width, zone.height / a.height)
    let w = a.width * k, h = a.height * k
    return min(zone.width / h, zone.height / w)
}

final class ConteneurTransforme: NSView {
    let enfant: NSView
    var rotation = 0
    var aspect: CGSize = .zero

    init(enfant: NSView) {
        self.enfant = enfant
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(enfant)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        enfant.frame = bounds
        // Rotation autour du centre (repère AppKit : y vers le haut, angle positif = sens antihoraire).
        let cx = bounds.midX, cy = bounds.midY
        let s = echelleRotation(zone: bounds.size, aspect: aspect, rotation: rotation)
        var t = CATransform3DMakeTranslation(-cx, -cy, 0)
        t = CATransform3DConcat(t, CATransform3DMakeRotation(-CGFloat(rotation) * .pi / 180, 0, 0, 1))
        t = CATransform3DConcat(t, CATransform3DMakeScale(s, s, 1))
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(cx, cy, 0))
        layer?.sublayerTransform = t
    }
}

final class VueNoire: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

