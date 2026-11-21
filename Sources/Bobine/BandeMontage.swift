import SwiftUI

/// Bande de montage : vignettes, forme d'onde du son, coupes (jaune), sélection (bleu), tête de lecture.
/// Glisser sur les vignettes = se déplacer ; glisser sur l'onde = sélectionner un passage.
/// Vue compacte : les passages supprimés disparaissent, un repère rouge (✂) les remplace.
struct BandeMontage: View {
    @ObservedObject var c: Controleur
    private let hVignettes: CGFloat = 46
    private let hOnde: CGFloat = 54
    private var hauteur: CGFloat { hVignettes + hOnde }
    @State private var departSelection: Double?
    @State private var enSelection = false

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                let axe = c.axe
                let l = max(c.longueurVue, 0.001)
                let d0 = c.debutVue
                let x: (Double) -> CGFloat = { u in CGFloat((u - d0) / l) * w }
                let xt: (Double) -> CGFloat = { t in x(axe.versAxe(t)) }

                ZStack(alignment: .topLeading) {
                    // Vignettes (une par case, comme dans un logiciel de montage)
                    Rectangle().fill(Color.gray.opacity(0.25))
                    ForEach(cases(axe: axe, d0: d0, l: l, w: w)) { k in
                        Image(nsImage: c.vignettes[k.image])
                            .resizable().aspectRatio(contentMode: .fill)
                            .frame(width: max(1, x(k.u1) - x(k.u0)), height: hVignettes)
                            .clipped()
                            .offset(x: x(k.u0))
                    }

                    // Forme d'onde (silences = creux : on coupe entre deux propos)
                    FormeOnde(onde: c.onde, axe: axe, debut: d0, longueur: l, sansSon: c.sansSon)
                        .equatable()
                        .frame(width: w, height: hOnde)
                        .offset(y: hVignettes)

                    // Sélection
                    if let e = c.entree, let s = c.sortie {
                        let xe = xt(e), xs = xt(s)
                        Rectangle().fill(Color.accentColor.opacity(0.3))
                            .frame(width: max(1, xs - xe), height: hauteur).offset(x: xe)
                        Rectangle().fill(Color.accentColor).frame(width: 2, height: hauteur).offset(x: xe - 1)
                        Rectangle().fill(Color.accentColor).frame(width: 2, height: hauteur).offset(x: xs - 1)
                    }

                    // Passages supprimés
                    if c.vueCompacte {
                        ForEach(c.montage.supprimes, id: \.self) { p in
                            let xp = xt(p.a)
                            if xp > -12 && xp < w + 12 {
                                Rectangle().fill(Color.red).frame(width: 2, height: hauteur).offset(x: xp - 1)
                                Button { c.restaurerPassage(p) } label: {
                                    Image(systemName: "scissors").font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 18, height: 18)
                                        .background(Circle().fill(Color.red))
                                }
                                .buttonStyle(.plain)
                                .help("\(formatTempsPrecis(p.longueur)) supprimées ici · cliquer pour les remettre")
                                .offset(x: xp - 9, y: hVignettes - 9)
                            }
                        }
                    } else {
                        ForEach(c.montage.supprimes, id: \.self) { p in
                            ZStack {
                                Rectangle().fill(Color.black.opacity(0.6))
                                Hachures().stroke(Color.red.opacity(0.8), lineWidth: 2)
                                if xt(p.b) - xt(p.a) > 24 {
                                    Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.red)
                                }
                            }
                            .frame(width: max(2, xt(p.b) - xt(p.a)), height: hauteur)
                            .clipped()
                            .offset(x: xt(p.a))
                        }
                    }

                    // Coupes (celles qui bordent un passage supprimé sont déjà marquées)
                    ForEach(coupesVisibles, id: \.self) { t in
                        Rectangle().fill(Color.yellow).frame(width: 2, height: hauteur).offset(x: xt(t) - 1)
                    }

                    // Tête de lecture
                    Rectangle().fill(Color.white).frame(width: 2, height: hauteur + 8)
                        .shadow(radius: 1).offset(x: xt(c.temps) - 1, y: -4)
                }
                .frame(width: w, height: hauteur)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let t = temps(v.location.x, w)
                            if v.startLocation.y > hVignettes {
                                // Sur l'onde : glisser = sélectionner
                                if departSelection == nil { departSelection = temps(v.startLocation.x, w) }
                                if abs(v.translation.width) > 3 { enSelection = true }
                                if enSelection, let d = departSelection { c.selectionner(d, t) }
                            } else {
                                c.glisse = true
                                c.aller(a: t, precis: false)
                            }
                        }
                        .onEnded { v in
                            let t = temps(v.location.x, w)
                            c.glisse = false
                            if enSelection {
                                if let e = c.entree { c.aller(a: e) }
                            } else {
                                if v.startLocation.y > hVignettes { c.effacerMarques() }
                                c.aller(a: t, precis: true)
                            }
                            departSelection = nil
                            enSelection = false
                        }
                )
            }
            .frame(height: hauteur)

            if c.zoom > 1.01 { BarreDefilement(c: c) }
        }
        .background(GeometryReader { g in
            Color.clear
                .onAppear { c.cadreBande = g.frame(in: .global) }
                .onChange(of: g.frame(in: .global)) { _, n in c.cadreBande = n }
                .onDisappear { c.cadreBande = .zero }
        })
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// Temps du fichier sous l'abscisse x de la bande.
    private func temps(_ px: CGFloat, _ w: CGFloat) -> Double {
        c.axe.versSource(c.debutVue + Double(px / max(w, 1)) * c.longueurVue)
    }

    private var coupesVisibles: [Double] {
        c.montage.coupes.filter { t in !c.montage.supprimes.contains { $0.a - 0.001 <= t && t <= $0.b + 0.001 } }
    }

    private struct Case: Identifiable { let id: Int; let image: Int; let u0: Double; let u1: Double }

    /// Cases de vignettes à largeur fixe, accrochées à l'axe (défilement fluide).
    private func cases(axe: Axe, d0: Double, l: Double, w: CGFloat) -> [Case] {
        let n = c.vignettes.count
        guard n > 0, c.duree > 0, w > 0 else { return [] }
        let ratio = c.tailleVideo.height > 0 ? Double(c.tailleVideo.width / c.tailleVideo.height) : 16.0 / 9
        let largeurCase = Double(hVignettes) * min(max(ratio, 0.5), 2.4)
        let su = largeurCase / Double(w) * l
        guard su > 0 else { return [] }
        let k0 = Int((d0 / su).rounded(.down)), k1 = Int(((d0 + l) / su).rounded(.up))
        guard k1 >= k0 else { return [] }
        return (k0...k1).map { k in
            let u0 = Double(k) * su
            let t = axe.versSource(min(u0 + su / 2, axe.longueur))
            let i = min(n - 1, max(0, Int(t / c.duree * Double(n))))
            return Case(id: k, image: i, u0: u0, u1: u0 + su)
        }
    }
}

/// Vue d'ensemble sous la bande quand on a zoomé : le cadre blanc = la portion affichée.
/// Le faire glisser (ou cliquer ailleurs) pour se déplacer, comme une barre de défilement.
struct BarreDefilement: View {
    @ObservedObject var c: Controleur
    @State private var prise: Double?

    var body: some View {
        GeometryReader { geo in
            let axe = c.axe
            let k = geo.size.width / CGFloat(max(axe.longueur, 0.001))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.25))
                if c.vueCompacte {
                    ForEach(Array(axe.departs.dropFirst()), id: \.self) { u in
                        Rectangle().fill(Color.red).frame(width: 1.5).offset(x: CGFloat(u) * k)
                    }
                } else {
                    ForEach(c.montage.supprimes, id: \.self) { p in
                        Rectangle().fill(Color.red.opacity(0.6))
                            .frame(width: max(1.5, CGFloat(p.longueur) * k)).offset(x: CGFloat(p.a) * k)
                    }
                }
                Rectangle().fill(Color.white).frame(width: 1.5).offset(x: CGFloat(axe.versAxe(c.temps)) * k)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.85), lineWidth: 1))
                    .frame(width: max(10, CGFloat(c.longueurVue) * k))
                    .offset(x: CGFloat(c.debutVue) * k)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let u = Double(v.location.x / max(k, 0.0001))
                        if prise == nil {
                            let dedans = u >= c.debutVue && u <= c.debutVue + c.longueurVue
                            prise = dedans ? u - c.debutVue : c.longueurVue / 2
                        }
                        c.debutVue = u - (prise ?? 0)
                        c.borner()
                    }
                    .onEnded { _ in prise = nil }
            )
            .help("Glissez pour parcourir la vidéo (ou deux doigts sur le trackpad au-dessus de la bande)")
        }
        .frame(height: 12)
    }
}

struct Hachures: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        var x = r.minX - r.height
        while x < r.maxX {
            p.move(to: CGPoint(x: x, y: r.maxY))
            p.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 10
        }
        return p
    }
}

/// Commandes de lecture et de montage.
struct BarreCommandes: View {
    @ObservedObject var c: Controleur
    @State private var aide = false

    var body: some View {
        VStack(spacing: 6) {
            if c.modeRecadrage { BarreRecadrage(c: c).padding(.horizontal, -12) }
            // La barre s'adapte à la largeur : on retire d'abord les curseurs, puis le reste du superflu.
            ViewThatFits(in: .horizontal) {
                ligne(0, legendes: true)   // fenêtre large : le nom sous chaque outil
                ligne(0)
                ligne(1)
                ligne(2)
            }

            HStack(spacing: 12) {
                if let m = c.message {
                    Text(m).font(.caption).foregroundStyle(.orange)
                } else if c.modeRecadrage {
                    Text("Glissez les coins ou le cadre · Entrée pour terminer")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let e = c.entree, let s = c.sortie {
                    Text("Sélection \(formatTempsPrecis(e)) → \(formatTempsPrecis(s)) (\(String(format: "%.1f", s - e)) s) · ⌫ pour la supprimer · Échap pour l'effacer")
                        .font(.caption).foregroundStyle(Color.accentColor).lineLimit(1)
                } else if !c.montage.estVide {
                    Text(resume).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !c.montage.supprimes.isEmpty {
                        Button(c.vueCompacte ? "Voir les passages supprimés" : "Masquer les passages supprimés") {
                            c.vueCompacte.toggle()
                        }.font(.caption)
                    }
                    Button("Tout restaurer") { c.toutRestaurer() }.font(.caption)
                } else {
                    Text("Glisser sur l'onde = sélectionner · ⌫ supprimer · C couper · R recadrer · F plein écran · deux doigts = défiler")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(c.estVLC ? "Moteur VLC" : "Moteur Apple").font(.caption).foregroundStyle(.tertiary)
                    .lineLimit(1).layoutPriority(-1)
                if !c.montage.estVide {
                    Button("Appliquer") { c.appliquer() }
                        .font(.caption)
                        .help("Fabrique le fichier monté à côté de l'original (qui reste intact) et le rouvre à la place (⇧⌘A)")
                }
                Menu("Exporter") {
                    ForEach(FormatExport.allCases) { f in Button(f.titre) { c.exporter(f) } }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([c.url]) }
                    .font(.caption).help("Afficher le fichier dans le Finder")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Rangée principale. niveau 0 : tout ; 1 : sans les curseurs zoom / volume ; 2 : l'essentiel.
    @ViewBuilder private func ligne(_ niveau: Int, legendes: Bool = false) -> some View {
        HStack(spacing: 10) {
            Button { c.allerAuDebut() } label: { Image(systemName: "backward.end.fill") }
                .help("Revenir au début du montage (fn + ←)")
            if niveau < 2 {
                Button { c.sauter(-5) } label: { Image(systemName: "gobackward.5") }.help("Reculer de 5 s (←)")
            }
            Button { c.basculer() } label: {
                Image(systemName: c.enLecture ? "pause.fill" : "play.fill").frame(width: 18)
            }.help("Lecture / pause (espace)")
            if niveau < 2 {
                Button { c.sauter(5) } label: { Image(systemName: "goforward.5") }.help("Avancer de 5 s (→)")
            }

            Text(niveau < 2 ? "\(formatTempsPrecis(c.temps)) / \(formatTemps(c.duree))" : formatTempsPrecis(c.temps))
                .monospacedDigit().font(.caption).fixedSize()

            Divider().frame(height: 16)

            Outil(icone: "scissors", mot: legendes ? "Couper" : nil, aide: "Couper à la tête de lecture (C)") { c.couper() }
            Outil(icone: "delete.left", mot: legendes ? "Supprimer" : nil,
                  aide: "Supprimer le passage sélectionné (glisser sur l'onde), sinon le morceau entre deux coupes ; rappuyer le remet (⌫)") { c.supprimer() }
            Outil(icone: "crop", mot: legendes ? "Recadrer" : nil, actif: c.modeRecadrage, aide: "Recadrer, pivoter (R)") { c.basculerRecadrage() }
            Outil(icone: "camera.filters", mot: legendes ? "Filtres" : nil, actif: c.montage.filtre != .aucun || c.modeFiltres,
                  aide: "Filtres de couleur façon iPhone") { c.basculerFiltres() }
            Outil(icone: "waveform.badge.plus", mot: legendes ? "Normaliser" : nil, actif: c.montage.normaliser,
                  aide: c.montage.normaliser ? "Son normalisé à l'export (-16 LUFS) · cliquer pour annuler"
                                             : "Normaliser le son : monter un son trop faible à un volume standard (-16 LUFS), appliqué à l'export") { c.basculerNormaliser() }
            if niveau < 2 {
                Button { c.annuler() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Annuler (⌘Z)").disabled(!c.peutAnnuler)
                Button { c.retablir() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Rétablir (⇧⌘Z)").disabled(!c.peutRetablir)
            }

            Spacer(minLength: 4)

            if niveau == 0 {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: Binding(get: { log(c.zoom) }, set: { c.zoomer(exp($0)) }), in: 0...log(max(c.zoomMax, 1.01)))
                    .frame(width: 90).help("Zoom de la bande (+ / −, ou molette au-dessus de la bande)")
            }
            if niveau < 2 {
                Menu("\(String(format: "%g", c.vitesse))×") {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 2] as [Float], id: \.self) { r in
                        Button("\(String(format: "%g", r))×") { c.vitesse = r }
                    }
                }.menuStyle(.borderlessButton).fixedSize()
            }
            if niveau == 0 {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                Slider(value: $c.volume, in: 0...1).frame(width: 70)
            }
            Button { c.basculerOutils() } label: { Image(systemName: "chevron.down") }
                .help("Replier les outils de montage : il ne reste que la lecture (T)")
        }
        .lineLimit(1)
    }

    private var resume: String {
        let m = c.montage
        var parts: [String] = []
        if !m.supprimes.isEmpty {
            let n = m.supprimes.count
            parts.append("\(formatTemps(m.dureeFinale(duree: c.duree))) sur \(formatTemps(c.duree)), \(n) passage\(n > 1 ? "s" : "") supprimé\(n > 1 ? "s" : "")")
        }
        if let r = m.recadrage, c.tailleVideo.width > 0 {
            var w = Int(r.width * c.tailleVideo.width), h = Int(r.height * c.tailleVideo.height)
            if m.rotation % 180 == 90 { swap(&w, &h) }
            parts.append("recadré \(w)×\(h)")
        }
        if m.rotation != 0 { parts.append("pivoté \(360 - m.rotation)° à gauche") }
        if m.filtre != .aucun { parts.append("filtre \(m.filtre.titre)") }
        if m.normaliser { parts.append("son normalisé") }
        return "Montage : " + parts.joined(separator: " · ")
    }
}

func formatTempsPrecis(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00.0" }
    let dixiemes = Int((s * 10).rounded(.down)) % 10
    return "\(formatTemps(s)).\(dixiemes)"
}

/// Bouton d'outil : une icône seule, assez grande, jaune quand l'outil est actif ; le nom est dans la bulle d'aide.
struct Outil: View {
    let icone: String
    var mot: String? = nil
    var actif = false
    let aide: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icone)
                    .font(.system(size: 17, weight: .regular))
                    .frame(width: 34, height: 24)
                if let mot { Text(mot).font(.system(size: 9.5)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(actif ? Color.yellow : Color.primary)
            .frame(minWidth: mot == nil ? 34 : 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(aide)
    }
}
