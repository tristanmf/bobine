import AppKit
import SwiftUI

/// Formats d'export proposés (ffmpeg, encodage matériel Apple : rapide).
enum FormatExport: String, CaseIterable, Identifiable {
    case mp4, mp4_1080, mp4_720, hevc, m4a, mp3
    var id: String { rawValue }

    var titre: String {
        switch self {
        case .mp4: return "MP4 compatible (QuickTime, iPhone, web)"
        case .mp4_1080: return "MP4 1080p"
        case .mp4_720: return "MP4 720p (léger)"
        case .hevc: return "HEVC (même qualité, plus léger)"
        case .m4a: return "Audio seul (M4A)"
        case .mp3: return "Audio seul (MP3)"
        }
    }
    var extensionFichier: String {
        switch self {
        case .m4a: return "m4a"
        case .mp3: return "mp3"
        default: return "mp4"
        }
    }
    var suffixe: String {
        switch self {
        case .mp4: return ""
        case .mp4_1080: return " 1080p"
        case .mp4_720: return " 720p"
        case .hevc: return " HEVC"
        case .m4a, .mp3: return " audio"
        }
    }
}

struct InfosMedia {
    var duree: Double = 0
    var codecVideo: String?
    var codecAudio: String?
    var largeur = 0
    var hauteur = 0

    static func lire(_ url: URL) -> InfosMedia {
        var i = InfosMedia()
        guard let ffprobe = Binaires.ffprobe else { return i }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = ["-v", "error", "-show_entries",
                       "stream=codec_type,codec_name,width,height:stream_tags=rotate:stream_side_data=rotation:format=duration",
                       "-of", "json", url.path]
        let tube = Pipe()
        p.standardOutput = tube
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return i }
        let data = tube.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return i }
        if let f = json["format"] as? [String: Any], let d = f["duration"] as? String {
            i.duree = Double(d) ?? 0
        }
        for s in (json["streams"] as? [[String: Any]]) ?? [] {
            let type = s["codec_type"] as? String, nom = s["codec_name"] as? String
            if type == "video", i.codecVideo == nil, nom != "mjpeg", nom != "png" {
                i.codecVideo = nom
                // Taille affichée : vidéos de téléphone tournées de ±90° → largeur et hauteur inversées.
                var w = s["width"] as? Int ?? 0, h = s["height"] as? Int ?? 0
                var rot = 0
                for sd in (s["side_data_list"] as? [[String: Any]]) ?? [] {
                    if let r = sd["rotation"] as? Int { rot = r } else if let r = sd["rotation"] as? Double { rot = Int(r) }
                }
                if rot == 0, let t = s["tags"] as? [String: Any], let r = t["rotate"] as? String { rot = Int(r) ?? 0 }
                if abs(rot) % 180 == 90 { swap(&w, &h) }
                i.largeur = w; i.hauteur = h
            }
            if type == "audio", i.codecAudio == nil { i.codecAudio = nom }
        }
        return i
    }
}

enum Export {
    /// Filtres image du montage : recadrage, puis rotation (ordre de l'aperçu).
    static func filtresImage(_ m: Montage?) -> [String] {
        guard let m else { return [] }
        var f: [String] = m.filtre.ffmpeg
        if let r = m.recadrage {
            f.append(String(format: "crop=trunc(iw*%.5f/2)*2:trunc(ih*%.5f/2)*2:trunc(iw*%.5f):trunc(ih*%.5f)",
                            r.width, r.height, r.minX, r.minY))
        }
        switch m.rotation {
        case 90: f.append("transpose=1")
        case 180: f.append("hflip,vflip")
        case 270: f.append("transpose=2")
        default: break
        }
        return f
    }

    /// Filtre son : volume normalisé (norme des plateformes, -16 LUFS) puis retour à 48 kHz.
    static func filtreSon(_ m: Montage?) -> String? {
        (m?.normaliser ?? false) ? "loudnorm=I=-16:TP=-1.5:LRA=11,aresample=48000" : nil
    }

    /// Construit la commande ffmpeg. `copie` = simple changement de conteneur (instantané).
    /// `garder` = morceaux à conserver (montage) ; `montage` porte aussi recadrage et rotation.
    static func arguments(source: URL, dest: URL, format: FormatExport, infos: InfosMedia,
                          garder: [Plage]? = nil, montage: Montage? = nil) -> (args: [String], copie: Bool) {
        var a = ["-hide_banner", "-y", "-i", source.path, "-progress", "pipe:1", "-nostats"]
        let audioAAC = ["-c:a", "aac", "-b:a", "192k"]
        let h264 = ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]
        let hevc = ["-c:v", "hevc_videotoolbox", "-q:v", "60", "-tag:v", "hvc1"]
        let audioSeul = format == .m4a || format == .mp3
        let video = !audioSeul && infos.codecVideo != nil
        let audio = infos.codecAudio != nil
        let son = audio ? filtreSon(montage) : nil

        var image = video ? filtresImage(montage) : []
        if video, format == .mp4_1080 || format == .mp4_720 {
            let h = format == .mp4_1080 ? 1080 : 720
            image.append("scale=-2:'min(\(h),trunc(ih/2)*2)'")
        }
        let codecs: [String] = {
            switch format {
            case .mp3: return ["-c:a", "libmp3lame", "-q:a", "2"]
            case .m4a: return audioAAC
            case .hevc: return (video ? hevc : []) + (audio ? audioAAC : [])
            default: return (video ? h264 : []) + (audio ? audioAAC : [])
            }
        }()
        // loudnorm rallonge le son d'une fraction de seconde : on le coupe à la longueur de l'image.
        let fin = (son != nil && video ? ["-shortest"] : []) + (format != .mp3 ? ["-movflags", "+faststart"] : []) + [dest.path]

        // Montage : chaque morceau gardé est une entrée à part, ouverte directement à son début
        // (-ss avant -i : ffmpeg saute au bon endroit au lieu de décoder tout ce qui précède ;
        // le réencodage garde la coupe à l'image près). Fondus de 10 ms sur le son contre les clics.
        if let garder, !garder.isEmpty {
            guard video || audio else { return (a + [dest.path], false) }
            let f3: (Double) -> String = { String(format: "%.3f", $0) }
            var b = ["-hide_banner", "-y"]
            for p in garder { b += ["-ss", f3(p.a), "-t", f3(p.longueur), "-i", source.path] }
            b += ["-progress", "pipe:1", "-nostats"]
            var parts: [String] = []
            var entrees = ""
            for (i, p) in garder.enumerated() {
                if video {
                    parts.append("[\(i):v:0]setpts=PTS-STARTPTS[v\(i)]")
                    entrees += "[v\(i)]"
                }
                if audio {
                    let fondu = min(0.01, p.longueur / 4)
                    parts.append("[\(i):a:0]asetpts=PTS-STARTPTS,"
                               + "afade=t=in:d=\(f3(fondu)),afade=t=out:st=\(f3(p.longueur - fondu)):d=\(f3(fondu))[a\(i)]")
                    entrees += "[a\(i)]"
                }
            }
            parts.append("\(entrees)concat=n=\(garder.count):v=\(video ? 1 : 0):a=\(audio ? 1 : 0)\(video ? "[v]" : "")\(audio ? "[a]" : "")")
            var sortieV = "[v]"
            if !image.isEmpty {
                parts.append("[v]\(image.joined(separator: ","))[vi]")
                sortieV = "[vi]"
            }
            var sortieA = "[a]"
            if let son { parts.append("[a]\(son)[an]"); sortieA = "[an]" }
            b += ["-filter_complex", parts.joined(separator: ";")]
            if video { b += ["-map", sortieV] }
            if audio { b += ["-map", sortieA] }
            return (b + codecs + fin, false)
        }

        // Fichier entier.
        let af = son.map { ["-af", $0] } ?? []
        if audioSeul { return (a + ["-vn", "-sn", "-dn"] + af + codecs + fin, false) }
        a += ["-map", "0:v:0?", "-map", "0:a:0?"]
        let v = infos.codecVideo, au = infos.codecAudio
        if format == .mp4, image.isEmpty, v == "h264" || v == "hevc" {
            a += ["-c:v", "copy"]
            if v == "hevc" { a += ["-tag:v", "hvc1"] }
            if au == nil || (au == "aac" && son == nil) {
                return (a + ["-c:a", "copy"] + fin, true)
            }
            return (a + af + audioAAC + fin, false) // image copiée, seul le son est réencodé
        }
        if !image.isEmpty { a += ["-vf", image.joined(separator: ",")] }
        return (a + af + codecs + fin, false)
    }

    /// Demande où enregistrer puis lance l'export. Renvoie false si l'utilisateur a annulé.
    @MainActor @discardableResult
    static func demander(source: URL, format: FormatExport, garder: [Plage]? = nil, montage: Montage? = nil) -> Bool {
        guard Binaires.ffmpeg != nil else {
            alerte("ffmpeg est introuvable.", "Dans le Terminal :  brew install ffmpeg")
            return false
        }
        let panneau = NSSavePanel()
        panneau.directoryURL = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let modifie = garder != nil || (montage?.aTransfo ?? false)
        let suffixe = (modifie ? " montage" : "") + format.suffixe
        panneau.nameFieldStringValue = "\(base)\(suffixe).\(format.extensionFichier)"
        panneau.canCreateDirectories = true
        panneau.title = modifie ? "Exporter le montage : \(format.titre)" : "Exporter : \(format.titre)"
        guard panneau.runModal() == .OK, let dest = panneau.url else { return false }
        if dest.standardizedFileURL == source.standardizedFileURL {
            alerte("Choisissez un autre nom", "Le fichier exporté ne peut pas remplacer l'original.")
            return false
        }
        Fenetres.partage.ouvrirExport(TacheExport(source: source, dest: dest, format: format, garder: garder, montage: montage))
        return true
    }

    /// Nom libre à côté de la source : « nom montage.ext », puis « nom montage 2.ext »…
    /// (« nom montage montage » évité quand on applique plusieurs fois de suite).
    static func nomLibre(source: URL, ext: String) -> URL {
        let dossier = source.deletingLastPathComponent()
        var base = source.deletingPathExtension().lastPathComponent
        if let r = base.range(of: #" montage( \d+)?$"#, options: .regularExpression) { base.removeSubrange(r) }
        var n = 1
        while true {
            let u = dossier.appendingPathComponent("\(base) montage\(n > 1 ? " \(n)" : "").\(ext)")
            if !FileManager.default.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    @MainActor
    static func alerte(_ titre: String, _ texte: String) {
        let a = NSAlert()
        a.messageText = titre
        a.informativeText = texte
        a.runModal()
    }
}

@MainActor
final class TacheExport: ObservableObject {
    let source: URL, dest: URL, format: FormatExport
    @Published var progression: Double = 0
    @Published var etat = "Préparation…"
    @Published var fini = false
    @Published var echec: String?
    private var process: Process?
    private var annule = false

    let garder: [Plage]?
    let montage: Montage?
    /// Appelé quand l'export a réussi (« Appliquer et rouvrir »).
    var apresSucces: ((URL) -> Void)?

    init(source: URL, dest: URL, format: FormatExport, garder: [Plage]? = nil, montage: Montage? = nil) {
        self.source = source; self.dest = dest; self.format = format; self.garder = garder; self.montage = montage
    }

    func lancer() {
        let source = source, dest = dest, format = format, garder = garder, montage = montage
        Task.detached {
            let infos = InfosMedia.lire(source)
            let (args, copie) = Export.arguments(source: source, dest: dest, format: format, infos: infos,
                                                 garder: garder, montage: montage)
            let duree = garder.map { $0.reduce(0) { $0 + $1.longueur } } ?? infos.duree
            await MainActor.run {
                self.etat = copie ? "Changement de conteneur (sans réencodage)…"
                    : (garder != nil ? "Montage et encodage…" : "Conversion…")
                self.executer(args: args, duree: duree)
            }
        }
    }

    private func executer(args: [String], duree: Double) {
        guard let ffmpeg = Binaires.ffmpeg else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        let sortie = Pipe(), erreurs = Pipe()
        p.standardOutput = sortie
        p.standardError = erreurs
        p.standardInput = FileHandle.nullDevice
        let journal = Journal()
        erreurs.fileHandleForReading.readabilityHandler = { h in
            if let s = String(data: h.availableData, encoding: .utf8) { journal.ajouter(s) }
        }
        sortie.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let s = String(data: h.availableData, encoding: .utf8) else { return }
            for ligne in s.split(separator: "\n") where ligne.hasPrefix("out_time_us=") {
                if let us = Double(ligne.dropFirst("out_time_us=".count)), duree > 0 {
                    let v = min(1, us / 1_000_000 / duree)
                    Task { @MainActor in self?.progression = v }
                }
            }
        }
        p.terminationHandler = { [weak self] pr in
            sortie.fileHandleForReading.readabilityHandler = nil
            erreurs.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                if self.annule {
                    try? FileManager.default.removeItem(at: self.dest)
                    self.echec = "Export annulé."
                } else if pr.terminationStatus == 0 {
                    self.progression = 1
                    self.fini = true
                    self.etat = "Terminé."
                } else {
                    let derniere = journal.texte.split(separator: "\n").suffix(3).joined(separator: "\n")
                    self.echec = "La conversion a échoué.\n\(derniere)"
                }
            }
        }
        do { try p.run(); process = p } catch { echec = "Impossible de lancer ffmpeg : \(error.localizedDescription)" }
    }

    func annuler() {
        annule = true
        process?.terminate()
    }
}

/// Fin du journal d'erreurs de ffmpeg, partagée entre fils d'exécution.
final class Journal: @unchecked Sendable {
    private let verrou = NSLock()
    private var contenu = ""
    func ajouter(_ s: String) { verrou.withLock { contenu = String((contenu + s).suffix(4000)) } }
    var texte: String { verrou.withLock { contenu } }
}

struct VueExport: View {
    @ObservedObject var t: TacheExport
    var fermer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t.dest.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
            Text(t.format.titre).font(.caption).foregroundStyle(.secondary)
            if let e = t.echec {
                Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                HStack { Spacer(); Button("Fermer", action: fermer).keyboardShortcut(.defaultAction) }
            } else if t.fini {
                ProgressView(value: 1)
                HStack {
                    Spacer()
                    Button("Afficher dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([t.dest]); fermer()
                    }
                    Button("Ouvrir") { Fenetres.partage.ouvrir(t.dest); fermer() }
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                ProgressView(value: t.progression)
                HStack {
                    Text(t.etat).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(t.progression * 100)) %").monospacedDigit().font(.caption)
                    Button("Annuler") { t.annuler() }
                }
            }
        }
        .padding(18)
        .frame(width: 420)
        .onAppear { t.lancer() }
        .onChange(of: t.fini) {
            if t.fini, let f = t.apresSucces { f(t.dest); fermer() }
        }
    }
}
