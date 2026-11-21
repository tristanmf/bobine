import Foundation

/// Localisation des binaires Homebrew : une app lancée du Finder n'hérite pas du PATH du shell.
enum Binaires {
    static func chemin(_ nom: String) -> String? {
        for dossier in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = "\(dossier)/\(nom)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
    static var ffmpeg: String? { chemin("ffmpeg") }
    static var ffprobe: String? { chemin("ffprobe") }
}

/// Dossier où vont les enregistrements : ~/Movies/Bobine (créé au besoin).
enum Dossiers {
    static var enregistrements: URL {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/Bobine", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func nouveauFichier(_ prefixe: String, ext: String) -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
        return enregistrements.appendingPathComponent("\(prefixe) \(f.string(from: Date())).\(ext)")
    }
}

func formatTemps(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "0:00" }
    let t = Int(s)
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}
