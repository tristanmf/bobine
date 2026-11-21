import SwiftUI

/// Formats de recadrage (rapport largeur/hauteur de l'image exportée).
enum Ratio: String, CaseIterable, Identifiable {
    case libre = "Libre", original = "Original", r16_9 = "16:9", r9_16 = "9:16",
         carre = "Carré", r4_5 = "4:5", r4_3 = "4:3", r3_4 = "3:4"
    var id: String { rawValue }

    var valeur: Double? {
        switch self {
        case .libre, .original: return nil
        case .r16_9: return 16.0 / 9
        case .r9_16: return 9.0 / 16
        case .carre: return 1
        case .r4_5: return 4.0 / 5
        case .r4_3: return 4.0 / 3
        case .r3_4: return 3.0 / 4
        }
    }

    /// Format équivalent après un quart de tour.
    var inverse: Ratio {
        switch self {
        case .r16_9: return .r9_16
        case .r9_16: return .r16_9
        case .r4_3: return .r3_4
        case .r3_4: return .r4_3
        case .r4_5: return .libre
        default: return self
        }
    }
}

/// Rectangle occupé par l'image dans la zone (ajustée sans déformation).
func rectVideo(zone: CGSize, aspect: CGSize) -> CGRect {
    let a = aspect.width > 0 && aspect.height > 0 ? aspect : CGSize(width: 16, height: 9)
    let k = min(zone.width / a.width, zone.height / a.height)
    let w = a.width * k, h = a.height * k
    return CGRect(x: (zone.width - w) / 2, y: (zone.height - h) / 2, width: w, height: h)
}

/// Cadre de recadrage dessiné sur l'image, dans le repère de l'image source ;
/// la vue entière tourne et se retourne comme l'aperçu vidéo.
struct VueRecadrage: View {
    @ObservedObject var c: Controleur
    @State private var depart: CGRect?

    var body: some View {
        GeometryReader { geo in
            let V = rectVideo(zone: geo.size, aspect: c.tailleVideo)
            let r = cadre(V)
            ZStack(alignment: .topLeading) {
                if c.montage.recadrage != nil {
                    // Zone hors cadre assombrie
                    Path { p in
                        p.addRect(CGRect(origin: .zero, size: geo.size).insetBy(dx: -geo.size.width, dy: -geo.size.height))
                        p.addRect(r)
                    }
                    .fill(Color.black.opacity(c.modeRecadrage ? 0.6 : 0.94), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                }

                if c.modeRecadrage {
                    // Tiers, bord, déplacement, poignées
                    Path { p in
                        for i in 1...2 {
                            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                        }
                    }
                    .stroke(Color.white.opacity(0.45), lineWidth: 0.7)
                    .allowsHitTesting(false)

                    Rectangle()
                        .strokeBorder(Color.white, lineWidth: 1.5)
                        .background(Color.white.opacity(0.001))
                        .frame(width: r.width, height: r.height)
                        .offset(x: r.minX, y: r.minY)
                        .gesture(glisserCadre(V))

                    ForEach(0..<4, id: \.self) { coin in
                        Poignee(coin: coin)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                            .offset(x: (coin % 2 == 0 ? r.minX : r.maxX) - 18,
                                    y: (coin < 2 ? r.minY : r.maxY) - 18)
                            .gesture(glisserCoin(coin, V))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .rotationEffect(.degrees(Double(c.montage.rotation)))
            .scaleEffect(echelleRotation(zone: geo.size, aspect: c.tailleVideo, rotation: c.montage.rotation))
        }
        .allowsHitTesting(c.modeRecadrage)
    }

    private func cadre(_ V: CGRect) -> CGRect {
        let n = c.montage.recadrage ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return CGRect(x: V.minX + n.minX * V.width, y: V.minY + n.minY * V.height,
                      width: n.width * V.width, height: n.height * V.height)
    }

    private func enregistrer(_ r: CGRect, _ V: CGRect) {
        guard V.width > 0, V.height > 0 else { return }
        c.definirCadre(CGRect(x: (r.minX - V.minX) / V.width, y: (r.minY - V.minY) / V.height,
                              width: r.width / V.width, height: r.height / V.height))
    }

    private func glisserCadre(_ V: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { g in
                if depart == nil { depart = cadre(V); c.debutGeste() }
                guard let d = depart else { return }
                var n = d.offsetBy(dx: g.translation.width, dy: g.translation.height)
                n.origin.x = min(max(n.minX, V.minX), V.maxX - n.width)
                n.origin.y = min(max(n.minY, V.minY), V.maxY - n.height)
                enregistrer(n, V)
            }
            .onEnded { _ in depart = nil; c.finGeste() }
    }

    /// coin : 0 haut-gauche, 1 haut-droit, 2 bas-gauche, 3 bas-droit.
    private func glisserCoin(_ coin: Int, _ V: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { g in
                if depart == nil { depart = cadre(V); c.debutGeste() }
                guard let d = depart else { return }
                let gauche = coin % 2 == 0, haut = coin < 2
                let ancre = CGPoint(x: gauche ? d.maxX : d.minX, y: haut ? d.maxY : d.minY)
                let p0 = CGPoint(x: gauche ? d.minX : d.maxX, y: haut ? d.minY : d.maxY)
                // Le coin ne peut pas dépasser l'image ni passer de l'autre côté de l'ancre.
                let px = min(max(p0.x + g.translation.width, V.minX), V.maxX)
                let py = min(max(p0.y + g.translation.height, V.minY), V.maxY)
                var w = gauche ? ancre.x - px : px - ancre.x
                var h = haut ? ancre.y - py : py - ancre.y
                let mini: CGFloat = 40
                w = max(w, mini); h = max(h, mini)
                if let rs = c.ratioSource.map({ CGFloat($0) }) {
                    if w / h > rs { w = h * rs } else { h = w / rs }
                }
                // Reste dans l'image.
                let maxW = gauche ? ancre.x - V.minX : V.maxX - ancre.x
                let maxH = haut ? ancre.y - V.minY : V.maxY - ancre.y
                if w > maxW { let k = maxW / w; w *= k; if c.ratioSource != nil { h *= k } }
                if h > maxH { let k = maxH / h; h *= k; if c.ratioSource != nil { w *= k } }
                let n = CGRect(x: gauche ? ancre.x - w : ancre.x, y: haut ? ancre.y - h : ancre.y, width: w, height: h)
                enregistrer(n, V)
            }
            .onEnded { _ in depart = nil; c.finGeste() }
    }
}

/// Poignée en L, comme sur iPhone.
struct Poignee: View {
    let coin: Int
    var body: some View {
        Path { p in
            let l: CGFloat = 16, m: CGFloat = 18
            let sx: CGFloat = coin % 2 == 0 ? 1 : -1, sy: CGFloat = coin < 2 ? 1 : -1
            p.move(to: CGPoint(x: m + sx * l, y: m))
            p.addLine(to: CGPoint(x: m, y: m))
            p.addLine(to: CGPoint(x: m, y: m + sy * l))
        }
        .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .square))
        .shadow(color: .black.opacity(0.5), radius: 1)
    }
}

/// Barre affichée en mode recadrage.
struct BarreRecadrage: View {
    @ObservedObject var c: Controleur
    var body: some View {
        HStack(spacing: 8) {
            ForEach(Ratio.allCases) { r in
                Button(r.rawValue) { c.choisirRatio(r) }
                    .buttonStyle(.bordered)
                    .tint(c.ratio == r ? .accentColor : nil)
                    .controlSize(.small)
            }
            Divider().frame(height: 16)
            Button { c.pivoter() } label: { Image(systemName: "rotate.left") }
                .help("Pivoter de 90° vers la gauche")
            Button("Réinitialiser") { c.reinitialiserCadre() }.controlSize(.small)
            Spacer()
            Button("OK") { c.terminerRecadrage() }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .help("Terminer le recadrage (Entrée)")
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }
}
