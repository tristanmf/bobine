import AppKit
import CoreImage
import SwiftUI

/// Filtres de couleur façon iPhone. Mêmes réglages pour l'aperçu (Core Image) et l'export (ffmpeg).
enum Filtre: String, CaseIterable, Identifiable {
    case aucun, eclatant, eclatantChaud, eclatantFroid, spectaculaire, spectaculaireChaud, spectaculaireFroid,
         mono, argentique, noir
    var id: String { rawValue }

    var titre: String {
        switch self {
        case .aucun: return "Original"
        case .eclatant: return "Éclatant"
        case .eclatantChaud: return "Éclatant chaud"
        case .eclatantFroid: return "Éclatant froid"
        case .spectaculaire: return "Spectaculaire"
        case .spectaculaireChaud: return "Spectac. chaud"
        case .spectaculaireFroid: return "Spectac. froid"
        case .mono: return "Mono"
        case .argentique: return "Argentique"
        case .noir: return "Noir"
        }
    }

    struct Reglages { var saturation = 1.0, contraste = 1.0, luminosite = 0.0, chaleur = 0.0 }

    var reglages: Reglages {
        switch self {
        case .aucun: return Reglages()
        case .eclatant: return Reglages(saturation: 1.35, contraste: 1.08, luminosite: 0.02)
        case .eclatantChaud: return Reglages(saturation: 1.35, contraste: 1.08, luminosite: 0.02, chaleur: 0.7)
        case .eclatantFroid: return Reglages(saturation: 1.35, contraste: 1.08, luminosite: 0.02, chaleur: -0.7)
        case .spectaculaire: return Reglages(saturation: 1.1, contraste: 1.3, luminosite: -0.04)
        case .spectaculaireChaud: return Reglages(saturation: 1.1, contraste: 1.3, luminosite: -0.04, chaleur: 0.7)
        case .spectaculaireFroid: return Reglages(saturation: 1.1, contraste: 1.3, luminosite: -0.04, chaleur: -0.7)
        case .mono: return Reglages(saturation: 0)
        case .argentique: return Reglages(saturation: 0, contraste: 1.15, luminosite: 0.03, chaleur: 0.3)
        case .noir: return Reglages(saturation: 0, contraste: 1.6, luminosite: -0.05)
        }
    }

    /// Le filtre est une seule transformation de couleur : sortie = M × entrée + biais (en sRGB, 0…1).
    /// Saturation (vers le gris, poids de luminance Rec. 709), puis contraste autour de 0,5 et luminosité,
    /// puis chaleur (rouge renforcé, bleu atténué, ou l'inverse). Même calcul pour l'aperçu et pour ffmpeg.
    var matrice: (m: [[Double]], biais: [Double]) {
        let r = reglages
        let poids = [0.2126, 0.7152, 0.0722]
        let canal = [1 + 0.08 * r.chaleur, 1.0, 1 - 0.08 * r.chaleur]
        var m: [[Double]] = [], biais: [Double] = []
        for i in 0..<3 {
            m.append((0..<3).map { j in canal[i] * r.contraste * ((1 - r.saturation) * poids[j] + (i == j ? r.saturation : 0)) })
            biais.append(canal[i] * (0.5 * (1 - r.contraste) + r.luminosite))
        }
        return (m, biais)
    }

    /// Calculs dans l'espace sRGB (comme ffmpeg), pour que l'aperçu ressemble à l'export.
    nonisolated(unsafe) static let contexte = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    ])

    func appliquer(_ i: CIImage) -> CIImage {
        guard self != .aucun else { return i }
        let (m, b) = matrice
        return i.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0),
            "inputGVector": CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0),
            "inputBVector": CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: b[0], y: b[1], z: b[2], w: 0),
        ])
        .applyingFilter("CIColorClamp")
        .cropped(to: i.extent)
    }

    /// Même transformation pour un calque (aperçu de la caméra en direct).
    var filtresCouche: [CIFilter]? {
        guard self != .aucun, let cm = CIFilter(name: "CIColorMatrix"), let cl = CIFilter(name: "CIColorClamp") else { return nil }
        let (m, b) = matrice
        cm.setValue(CIVector(x: m[0][0], y: m[0][1], z: m[0][2], w: 0), forKey: "inputRVector")
        cm.setValue(CIVector(x: m[1][0], y: m[1][1], z: m[1][2], w: 0), forKey: "inputGVector")
        cm.setValue(CIVector(x: m[2][0], y: m[2][1], z: m[2][2], w: 0), forKey: "inputBVector")
        cm.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        cm.setValue(CIVector(x: b[0], y: b[1], z: b[2], w: 0), forKey: "inputBiasVector")
        return [cm, cl]
    }

    /// Filtres ffmpeg équivalents (le canal alpha, opaque, sert à ajouter le biais).
    var ffmpeg: [String] {
        guard self != .aucun else { return [] }
        let (m, b) = matrice
        let n = ["r", "g", "b"]
        var p: [String] = []
        for i in 0..<3 {
            for j in 0..<3 { p.append(String(format: "%@%@=%.4f", n[i], n[j], m[i][j])) }
            p.append(String(format: "%@a=%.4f", n[i], b[i]))
        }
        return ["format=rgba", "colorchannelmixer=" + p.joined(separator: ":")]
    }

    /// Réglages du filtre « adjust » de VLC (aperçu avec le moteur VLC ; sans la teinte chaude/froide).
    var vlc: (contraste: Float, luminosite: Float, saturation: Float) {
        let r = reglages
        return (Float(r.contraste), Float(1 + r.luminosite * 2), Float(r.saturation))
    }

    /// Petite image d'exemple pour le choix du filtre.
    func apercu(_ image: NSImage) -> NSImage {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let sortie = appliquer(CIImage(cgImage: cg))
        guard let res = Self.contexte.createCGImage(sortie, from: sortie.extent) else { return image }
        return NSImage(cgImage: res, size: image.size)
    }
}

extension Filtre {
    /// Auto-test : couleur moyenne d'une image filtrée par Core Image (aperçu) et par ffmpeg (export).
    static func comparer(source: URL, dossier: String) {
        guard let ffmpeg = Binaires.ffmpeg else { return }
        func lancer(_ args: [String]) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: ffmpeg); p.arguments = args
            p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
        }
        func moyenne(_ i: CIImage) -> String {
            let f = i.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: i.extent)])
            var px = [UInt8](repeating: 0, count: 4)
            contexte.render(f, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return "\(px[0]),\(px[1]),\(px[2])"
        }
        let base = "\(dossier)/image-source.png"
        lancer(["-y", "-v", "error", "-ss", "1", "-i", source.path, "-frames:v", "1", base])
        guard let ci = CIImage(contentsOf: URL(fileURLWithPath: base)) else { return }
        for f in [Filtre.aucun, .eclatantChaud, .spectaculaireFroid, .noir, .argentique] {
            let sortie = "\(dossier)/image-\(f.rawValue).png"
            lancer(["-y", "-v", "error", "-i", base, "-vf", (f.ffmpeg + ["format=rgb24"]).joined(separator: ","), sortie])
            let ff = CIImage(contentsOf: URL(fileURLWithPath: sortie)).map(moyenne) ?? "?"
            MoteurVLC.trace("AUTOTEST filtre \(f.titre) : aperçu=\(moyenne(f.appliquer(ci))) export=\(ff)")
        }
    }
}

/// Rangée des filtres (comme dans Photos sur iPhone) : un aperçu de l'image par filtre.
struct BarreFiltres: View {
    @ObservedObject var c: Controleur
    @State private var apercus: [Filtre: NSImage] = [:]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Filtre.allCases) { f in
                    Button { c.choisirFiltre(f) } label: {
                        VStack(spacing: 3) {
                            Group {
                                if let i = apercus[f] {
                                    Image(nsImage: i).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(Color.gray.opacity(0.3))
                                }
                            }
                            .frame(width: 72, height: 48).clipped()
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(c.montage.filtre == f ? Color.yellow : Color.clear, lineWidth: 2))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(f.titre).font(.caption2)
                                .foregroundStyle(c.montage.filtre == f ? Color.yellow : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 8)
                Button("OK") { c.modeFiltres = false }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 12)
        }
        .onAppear(perform: calculer)
        .onChange(of: c.vignettes.count) { calculer() }
    }

    private func calculer() {
        guard !c.vignettes.isEmpty else { return }
        let i = min(c.vignettes.count - 1, max(0, Int(c.temps / max(c.duree, 0.001) * Double(c.vignettes.count))))
        let base = c.vignettes[i]
        var res: [Filtre: NSImage] = [:]
        for f in Filtre.allCases { res[f] = f.apercu(base) }
        apercus = res
    }
}
