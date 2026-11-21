import AppKit
import Foundation

/// Accès au moteur de lecture de VLC (libvlc) chargé depuis /Applications/VLC.app.
/// Rien n'est copié ni téléchargé : Bobine utilise le VLC installé (et ses mises à jour).
final class MoteurVLC {
    static let cheminApp = "/Applications/VLC.app/Contents/MacOS"
    static let partage = MoteurVLC()

    private typealias FNew = @convention(c) (Int32, UnsafePointer<UnsafePointer<CChar>?>?) -> OpaquePointer?
    private typealias FMediaPath = @convention(c) (OpaquePointer?, UnsafePointer<CChar>) -> OpaquePointer?
    private typealias FPtr = @convention(c) (OpaquePointer?) -> Void
    private typealias FPlayerFromMedia = @convention(c) (OpaquePointer?) -> OpaquePointer?
    private typealias FSetNSObject = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Void
    private typealias FInt = @convention(c) (OpaquePointer?) -> Int32
    private typealias FSetInt = @convention(c) (OpaquePointer?, Int32) -> Void
    private typealias FSetIntRet = @convention(c) (OpaquePointer?, Int32) -> Int32
    private typealias FTime = @convention(c) (OpaquePointer?) -> Int64
    private typealias FSetTime = @convention(c) (OpaquePointer?, Int64) -> Void
    private typealias FSetRate = @convention(c) (OpaquePointer?, Float) -> Int32

    private(set) var instance: OpaquePointer?
    private(set) var erreur: String?

    private var fMediaPath: FMediaPath!
    private var fMediaRelease: FPtr!
    private var fPlayerFromMedia: FPlayerFromMedia!
    private var fPlayerRelease: FPtr!
    private var fSetNSObject: FSetNSObject!
    private var fPlay: FInt!
    private var fSetPause: FSetInt!
    private var fStop: FPtr!
    private var fIsPlaying: FInt!
    private var fGetTime: FTime!
    private var fGetLength: FTime!
    private var fSetTime: FSetTime!
    private var fSetVolume: FSetIntRet!
    private var fSetRate: FSetRate!
    private typealias FSnapshot = @convention(c) (OpaquePointer?, UInt32, UnsafePointer<CChar>, UInt32, UInt32) -> Int32
    private var fSnapshot: FSnapshot?
    private typealias FAdjInt = @convention(c) (OpaquePointer?, UInt32, Int32) -> Void
    private typealias FAdjFloat = @convention(c) (OpaquePointer?, UInt32, Float) -> Void
    private var fAdjInt: FAdjInt?
    private var fAdjFloat: FAdjFloat?
    private var fGetState: FInt?
    private var fSeekable: FInt?

    var disponible: Bool { instance != nil }

    private init() {
        let lib = "\(Self.cheminApp)/lib/libvlc.dylib"
        guard FileManager.default.fileExists(atPath: lib) else {
            erreur = "VLC n'est pas installé dans /Applications. Installez-le (videolan.org) pour lire ce format."
            return
        }
        setenv("VLC_PLUGIN_PATH", "\(Self.cheminApp)/plugins", 1)
        // libvlc cherche libvlccore via @rpath : on la charge d'abord par son chemin complet.
        _ = dlopen("\(Self.cheminApp)/lib/libvlccore.dylib", RTLD_NOW | RTLD_GLOBAL)
        guard let h = dlopen(lib, RTLD_NOW | RTLD_GLOBAL) else {
            erreur = "Impossible de charger le moteur de VLC : \(String(cString: dlerror()))"
            return
        }
        func f<T>(_ nom: String, _: T.Type) -> T? {
            guard let p = dlsym(h, nom) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let fNew = f("libvlc_new", FNew.self),
              let a = f("libvlc_media_new_path", FMediaPath.self),
              let b = f("libvlc_media_release", FPtr.self),
              let c = f("libvlc_media_player_new_from_media", FPlayerFromMedia.self),
              let d = f("libvlc_media_player_release", FPtr.self),
              let e = f("libvlc_media_player_set_nsobject", FSetNSObject.self),
              let g = f("libvlc_media_player_play", FInt.self),
              let i = f("libvlc_media_player_set_pause", FSetInt.self),
              let j = f("libvlc_media_player_stop", FPtr.self),
              let k = f("libvlc_media_player_is_playing", FInt.self),
              let l = f("libvlc_media_player_get_time", FTime.self),
              let m = f("libvlc_media_player_get_length", FTime.self),
              let n = f("libvlc_media_player_set_time", FSetTime.self),
              let o = f("libvlc_audio_set_volume", FSetIntRet.self),
              let p = f("libvlc_media_player_set_rate", FSetRate.self)
        else {
            erreur = "Version de VLC incompatible (fonctions introuvables)."
            return
        }
        fMediaPath = a; fMediaRelease = b; fPlayerFromMedia = c; fPlayerRelease = d
        fSetNSObject = e; fPlay = g; fSetPause = i; fStop = j; fIsPlaying = k
        fGetTime = l; fGetLength = m; fSetTime = n; fSetVolume = o; fSetRate = p
        fSnapshot = f("libvlc_video_take_snapshot", FSnapshot.self)
        fAdjInt = f("libvlc_video_set_adjust_int", FAdjInt.self)
        fAdjFloat = f("libvlc_video_set_adjust_float", FAdjFloat.self)
        fGetState = f("libvlc_media_player_get_state", FInt.self)
        fSeekable = f("libvlc_media_player_is_seekable", FInt.self)

        // Pas de recherche de pochette (album-art) ni d'accès réseau aux métadonnées : sur un fichier
        // étiqueté (artiste, album), VLC peut sinon rester plusieurs secondes « en ouverture ».
        let args = ["--no-video-title-show", "--no-stats", "--quiet", "--album-art=0", "--no-metadata-network-access", "--no-sub-autodetect-file"]
        let cArgs = args.map { UnsafePointer<CChar>(strdup($0)) }
        instance = cArgs.withUnsafeBufferPointer { buf in
            buf.baseAddress!.withMemoryRebound(to: UnsafePointer<CChar>?.self, capacity: cArgs.count) {
                fNew(Int32(cArgs.count), $0)
            }
        }
        cArgs.forEach { free(UnsafeMutablePointer(mutating: $0)) }
        if instance == nil { erreur = "Le moteur de VLC n'a pas démarré." }
    }

    /// Journal de diagnostic (lisible avec : log stream --predicate 'process == "Bobine"').
    static func trace(_ s: String) {
        NSLog("Bobine: %@", s)
        // Journal local (lisible sans droits spéciaux) : ~/Library/Logs/Bobine.log, remis à zéro au-delà de 2 Mo.
        let journal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Bobine.log")
        let horo = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
        let l = Data("\(horo) [\(ProcessInfo.processInfo.processIdentifier)] \(s)\n".utf8)
        if let a = try? FileManager.default.attributesOfItem(atPath: journal.path), (a[.size] as? Int ?? 0) > 2_000_000 {
            try? FileManager.default.removeItem(at: journal)
        }
        if let h = try? FileHandle(forWritingTo: journal) { h.seekToEndOfFile(); h.write(l); try? h.close() }
        else { try? l.write(to: journal) }
        // Auto-test : BOBINE_AUTOTEST=<dossier> → les traces vont aussi dans <dossier>/autotest.log
        if let d = ProcessInfo.processInfo.environment["BOBINE_AUTOTEST"] {
            let u = URL(fileURLWithPath: d).appendingPathComponent("autotest.log")
            let ligne = Data((s + "\n").utf8)
            if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(ligne); try? h.close() }
            else { try? ligne.write(to: u) }
        }
    }

    // MARK: - Lecteur

    final class Lecteur {
        private let m = MoteurVLC.partage
        private var mp: OpaquePointer?

        init?(url: URL, vue: NSView) {
            guard m.disponible else { return nil }
            guard let media = url.path.withCString({ m.fMediaPath(m.instance, $0) }) else { return nil }
            mp = m.fPlayerFromMedia(media)
            m.fMediaRelease(media)
            guard mp != nil else { return nil }
            m.fSetNSObject(mp, Unmanaged.passUnretained(vue).toOpaque())
        }

        func lire() { _ = m.fPlay(mp) }
        func pause() { m.fSetPause(mp, 1) }
        var enLecture: Bool { m.fIsPlaying(mp) != 0 }
        /// Fichier pas encore ouvert (0 rien, 1 ouverture).
        var ouverture: Bool { let e = m.fGetState?(mp) ?? 3; return e == 0 || e == 1 }
        /// Ouverture (1) ou mise en mémoire tampon (2) en cours.
        var occupe: Bool { let e = m.fGetState?(mp) ?? 3; return e == 1 || e == 2 }
        /// État de VLC (3 lecture, 4 pause, 5 arrêt, 6 fin, 7 erreur) et possibilité de sauter : diagnostic.
        var diagnostic: String { "état=\(m.fGetState?(mp) ?? -1) sautable=\(m.fSeekable?(mp) ?? -1)" }
        /// En secondes.
        var temps: Double { max(0, Double(m.fGetTime(mp)) / 1000) }
        var duree: Double { max(0, Double(m.fGetLength(mp)) / 1000) }
        func aller(a secondes: Double) { m.fSetTime(mp, Int64((secondes * 1000).rounded())) }
        func volume(_ v: Double) { _ = m.fSetVolume(mp, Int32(v * 100)) }
        func vitesse(_ r: Float) { _ = m.fSetRate(mp, r) }
        /// Instantané de l'image en cours (PNG). Sert à l'auto-test.
        func instantane(_ chemin: String) -> Bool {
            guard let s = m.fSnapshot else { return false }
            return chemin.withCString { s(mp, 0, $0, 0, 0) } == 0
        }

        /// Filtre « adjust » de VLC (aperçu des filtres de couleur). nil = désactivé.
        func couleur(_ r: (contraste: Float, luminosite: Float, saturation: Float)?) {
            guard let i = m.fAdjInt, let f = m.fAdjFloat else { return }
            // 0 = activer, 1 = contraste, 2 = luminosité, 3 = teinte, 4 = saturation, 5 = gamma
            if let r {
                f(mp, 1, r.contraste); f(mp, 2, r.luminosite); f(mp, 4, r.saturation)
                i(mp, 0, 1)
            } else {
                i(mp, 0, 0)
            }
        }

        func fermer() {
            guard let p = mp else { return }
            m.fStop(p)
            m.fPlayerRelease(p)
            mp = nil
        }
        deinit { fermer() }
    }
}
