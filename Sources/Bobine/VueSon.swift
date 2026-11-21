import SwiftUI

/// Visuel des fichiers son (pas d'image) : un disque jaune acide, la couleur de Bobine, entouré d'une
/// couronne de barres qui suit le vrai volume du son (forme d'onde calculée par ffmpeg), sur fond sombre.
struct VueSon: View {
    @ObservedObject var c: Controleur
    @StateObject private var horloge = Horloge()

    private static let jaune = Color(red: 0.90, green: 1.0, blue: 0.23)   // #E6FF3A, celle du logo
    private static let vert = Color(red: 0.35, green: 0.85, blue: 0.55)   // celle de la forme d'onde

    var body: some View {
        TimelineView(.animation(paused: !c.enLecture)) { tl in
            let t = horloge.temps(c.temps, lecture: c.enLecture, vitesse: Double(c.vitesse), maintenant: tl.date)
            let niveau = Double(c.onde?.pic(de: t - 0.05, a: t + 0.05) ?? 0)
            Canvas { ctx, taille in
                dessiner(&ctx, taille: taille, t: t, niveau: niveau)
            }
            .overlay(alignment: .bottom) {
                Text(c.url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 40).padding(.bottom, 22)
            }
        }
        .background(
            LinearGradient(colors: [Color(red: 0.10, green: 0.08, blue: 0.16), Color(red: 0.03, green: 0.03, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
        )
        .allowsHitTesting(false)
    }

    private func dessiner(_ ctx: inout GraphicsContext, taille: CGSize, t: Double, niveau: Double) {
        let centre = CGPoint(x: taille.width / 2, y: taille.height / 2 - 10)
        let base = min(taille.width, taille.height)
        let rayon = base * 0.17 * (1 + 0.05 * niveau)

        // Halo qui respire avec le son.
        let halo = rayon * (2.2 + 0.6 * niveau)
        ctx.fill(Path(ellipseIn: CGRect(x: centre.x - halo, y: centre.y - halo, width: 2 * halo, height: 2 * halo)),
                 with: .radialGradient(Gradient(colors: [Self.jaune.opacity(0.10 + 0.18 * niveau), .clear]),
                                       center: centre, startRadius: rayon * 0.8, endRadius: halo))

        // Couronne de barres : le son des 2 dernières secondes, en miroir gauche / droite.
        let n = 48
        for i in 0..<n {
            let k = i < n / 2 ? i : n - 1 - i
            let ti = t - Double(k) * 0.045
            let v = ti >= 0 ? Double(c.onde?.pic(de: ti - 0.02, a: ti + 0.02) ?? 0) : 0
            let angle = Double(i) / Double(n) * 2 * .pi - .pi / 2 + .pi / Double(n)
            let r0 = rayon * 1.22
            let longueur = rayon * (0.06 + 0.75 * v)
            let dx = cos(angle), dy = sin(angle)
            var trait = Path()
            trait.move(to: CGPoint(x: centre.x + dx * r0, y: centre.y + dy * r0))
            trait.addLine(to: CGPoint(x: centre.x + dx * (r0 + longueur), y: centre.y + dy * (r0 + longueur)))
            let couleur = v > 0.6 ? Self.jaune : Self.vert
            ctx.stroke(trait, with: .color(couleur.opacity(0.35 + 0.65 * v)),
                       style: StrokeStyle(lineWidth: max(2, base * 0.009), lineCap: .round))
        }

        // Le disque : jaune acide, avec la « bobine » noire et ses deux yeux de travers (comme l'icône).
        ctx.fill(Path(ellipseIn: CGRect(x: centre.x - rayon, y: centre.y - rayon, width: 2 * rayon, height: 2 * rayon)),
                 with: .color(Self.jaune))
        let r2 = rayon * 0.72
        ctx.fill(Path(ellipseIn: CGRect(x: centre.x - r2, y: centre.y - r2, width: 2 * r2, height: 2 * r2)),
                 with: .color(Color(white: 0.07)))
        func oeil(_ x: Double, _ y: Double, _ r: Double, _ p: Double) {
            let o = CGPoint(x: centre.x + x * r2, y: centre.y + y * r2)
            ctx.fill(Path(ellipseIn: CGRect(x: o.x - r * r2, y: o.y - r * r2, width: 2 * r * r2, height: 2 * r * r2)),
                     with: .color(Self.jaune))
            // La pupille regarde le son : elle monte un peu quand le volume monte.
            let q = CGPoint(x: o.x - r * r2 * 0.35, y: o.y - r * r2 * (0.25 + 0.3 * niveau))
            ctx.fill(Path(ellipseIn: CGRect(x: q.x - p * r2, y: q.y - p * r2, width: 2 * p * r2, height: 2 * p * r2)),
                     with: .color(Color(white: 0.07)))
        }
        oeil(-0.32, -0.18, 0.27, 0.12)
        oeil(0.38, -0.25, 0.16, 0.07)
        // La bouche : un petit triangle de lecture.
        let b = CGPoint(x: centre.x - r2 * 0.12, y: centre.y + r2 * 0.40)
        var bouche = Path()
        bouche.move(to: CGPoint(x: b.x, y: b.y - r2 * 0.17))
        bouche.addLine(to: CGPoint(x: b.x, y: b.y + r2 * 0.17))
        bouche.addLine(to: CGPoint(x: b.x + r2 * 0.30, y: b.y))
        bouche.closeSubpath()
        ctx.fill(bouche, with: .color(Self.jaune))
    }
}

/// Lisse la position : le moteur ne la donne que par à-coups (VLC : tous les 250 ms environ),
/// on avance donc entre deux relevés au rythme de la lecture.
@MainActor
final class Horloge: ObservableObject {
    private var dernier = -1.0
    private var date = Date()

    func temps(_ t: Double, lecture: Bool, vitesse: Double, maintenant: Date) -> Double {
        if t != dernier { dernier = t; date = maintenant }
        guard lecture else { return t }
        return t + min(0.6, maintenant.timeIntervalSince(date) * vitesse)
    }
}
