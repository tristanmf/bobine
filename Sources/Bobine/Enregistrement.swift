@preconcurrency import AVFoundation
import SwiftUI

enum ModeEnregistrement: String, CaseIterable, Identifiable {
    case camera = "Caméra", audio = "Audio"
    var id: String { rawValue }
    var icone: String {
        switch self { case .camera: "video.fill"; case .audio: "mic.fill" }
    }
}

/// Qualité d'enregistrement, comme dans QuickTime (le poids indiqué est un ordre de grandeur).
enum Qualite: String, CaseIterable, Identifiable {
    case leger, moyen, max
    var id: String { rawValue }
    var titre: String {
        switch self { case .leger: "Léger"; case .moyen: "Moyen"; case .max: "Maximum" }
    }
    var detailVideo: String {
        switch self {
        case .leger: "720p, HEVC · ≈ 25 Mo par minute"
        case .moyen: "1080p, H.264 (compatible partout) · ≈ 100 Mo par minute"
        case .max: "pleine définition de la caméra, ProRes · 1 Go par minute et plus"
        }
    }
    var detailAudio: String {
        switch self {
        case .leger: "AAC mono 64 kb/s · ≈ 0,5 Mo par minute"
        case .moyen: "AAC stéréo 192 kb/s · ≈ 1,5 Mo par minute"
        case .max: "sans perte (Apple Lossless) · ≈ 15 Mo par minute"
        }
    }
    var preset: AVCaptureSession.Preset {
        switch self { case .leger: .hd1280x720; case .moyen: .hd1920x1080; case .max: .hd4K3840x2160 }
    }
    var codec: AVVideoCodecType {
        switch self { case .leger: .hevc; case .moyen: .h264; case .max: .proRes422 }
    }
    /// À quoi ça sert (affiché dans le choix).
    var usageVideo: String {
        switch self {
        case .leger: "pour envoyer par mail ou par messagerie"
        case .moyen: "pour les réseaux sociaux, YouTube, une visio"
        case .max: "pour un vrai montage, des archives, une projection"
        }
    }
    var usageAudio: String {
        switch self {
        case .leger: "pour une note vocale, un mémo, un envoi par mail"
        case .moyen: "pour une interview, un podcast, les réseaux"
        case .max: "pour de la musique ou un montage son soigné"
        }
    }
    var reglagesAudio: [String: Any] {
        switch self {
        case .leger: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64000]
        case .moyen: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000]
        case .max: [AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 24]
        }
    }
    /// Format de l'export qui applique le filtre de couleur après l'enregistrement.
    var formatFiltre: FormatExport { self == .moyen ? .mp4 : .hevc }
}

/// Petite image de la caméra, 2 à 3 fois par seconde, pour les aperçus des filtres (fenêtre large).
final class CaptureVignettes: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let sortie = AVCaptureVideoDataOutput()
    private let file = DispatchQueue(label: "bobine.vignettes")
    private var derniere = Date.distantPast
    var recevoir: (@Sendable (CGImage) -> Void)?

    override init() {
        super.init()
        sortie.alwaysDiscardsLateVideoFrames = true
        sortie.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        sortie.setSampleBufferDelegate(self, queue: file)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(derniere) > 0.4, let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        derniere = Date()
        let i = CIImage(cvPixelBuffer: pb)
        let k = 240 / max(i.extent.width, 1)
        let petit = i.transformed(by: CGAffineTransform(scaleX: k, y: k))
        guard let cg = Filtre.contexte.createCGImage(petit, from: petit.extent) else { return }
        recevoir?(cg)
    }
}

/// Enregistrement caméra / audio (AVFoundation) : les mêmes briques système que QuickTime.
/// Les effets caméra (Studio, Portrait, Cadre centré) et les modes micro (Isolation de la voix)
/// sont ceux de macOS ; les filtres de couleur sont ceux de Bobine (aperçu en direct, appliqués
/// au fichier à la fin de l'enregistrement).
@MainActor
final class Enregistreur: NSObject, ObservableObject {
    @Published var mode: ModeEnregistrement = .camera { didSet { if mode != oldValue { reconfigurer() } } }
    @Published var cameras: [AVCaptureDevice] = []
    @Published var micros: [AVCaptureDevice] = []
    @Published var cameraID: String? { didSet { if cameraID != oldValue { reconfigurer() } } }
    @Published var microID: String? { didSet { if microID != oldValue { reconfigurer() } } }
    @Published var qualiteVideo = Qualite(rawValue: UserDefaults.standard.string(forKey: "qualiteVideo") ?? "") ?? .moyen {
        didSet { UserDefaults.standard.set(qualiteVideo.rawValue, forKey: "qualiteVideo"); if qualiteVideo != oldValue { reconfigurer() } }
    }
    @Published var qualiteAudio = Qualite(rawValue: UserDefaults.standard.string(forKey: "qualiteAudio") ?? "") ?? .moyen {
        didSet { UserDefaults.standard.set(qualiteAudio.rawValue, forKey: "qualiteAudio") }
    }
    @Published var filtre: Filtre = .aucun
    @Published var enCours = false
    @Published var debut: Date?
    @Published var message: String?

    let session = AVCaptureSession()
    private let fileSession = DispatchQueue(label: "bobine.capture")
    private let sortieFilm = AVCaptureMovieFileOutput()
    private let sortieAudio = AVCaptureAudioFileOutput()
    let vignettes = CaptureVignettes()
    /// Dernière petite image de la caméra (aperçus des filtres).
    @Published var image: NSImage?
    private var fichierEnCours: URL?
    /// Filtre choisi au début de l'enregistrement (appliqué au fichier à la fin).
    private var filtreEnregistre: Filtre = .aucun

    func preparer() {
        Enregistreur.courant = self
        vignettes.recevoir = { cg in
            Task { @MainActor [weak self] in self?.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
        Task {
            let okV = await AVCaptureDevice.requestAccess(for: .video)
            let okA = await AVCaptureDevice.requestAccess(for: .audio)
            if !okV && mode == .camera { message = "Accès à la caméra refusé : Réglages Système › Confidentialité › Caméra." }
            if !okA { message = "Accès au micro refusé : Réglages Système › Confidentialité › Micro." }
            listerAppareils()
            reconfigurer()
        }
    }

    func listerAppareils() {
        cameras = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video, position: .unspecified).devices
        micros = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        if cameraID == nil { cameraID = AVCaptureDevice.default(for: .video)?.uniqueID ?? cameras.first?.uniqueID }
        if microID == nil { microID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? micros.first?.uniqueID }
    }

    /// Reconstruit la session caméra/micro selon le mode et les appareils choisis.
    func reconfigurer() {
        guard !enCours else { return }
        let mode = mode
        let cam = cameras.first { $0.uniqueID == cameraID }
        let mic = micros.first { $0.uniqueID == microID }
        let session = session, sortieFilm = sortieFilm, sortieAudio = sortieAudio, sortieImages = vignettes.sortie
        let q = qualiteVideo
        fileSession.async {
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            if mode == .camera, let cam, let e = try? AVCaptureDeviceInput(device: cam), session.canAddInput(e) {
                session.addInput(e)
                // Qualité demandée, sinon la meilleure en dessous que la caméra accepte.
                let presets: [AVCaptureSession.Preset] = [q.preset, .hd1920x1080, .high, .hd1280x720]
                if let p = presets.first(where: { session.canSetSessionPreset($0) }) { session.sessionPreset = p }
            }
            if let mic, let e = try? AVCaptureDeviceInput(device: mic), session.canAddInput(e) {
                session.addInput(e)
            }
            if mode == .camera, session.canAddOutput(sortieFilm) { session.addOutput(sortieFilm) }
            if mode == .camera, session.canAddOutput(sortieImages) { session.addOutput(sortieImages) }
            if mode == .audio, session.canAddOutput(sortieAudio) { session.addOutput(sortieAudio) }
            session.commitConfiguration()
            if mode == .camera, let c = sortieFilm.connection(with: .video) {
                sortieFilm.setOutputSettings([AVVideoCodecKey: q.codec], for: c)
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func basculer() { enCours ? arreter() : demarrer() }

    private func demarrer() {
        message = nil
        switch mode {
        case .camera:
            // Avec un filtre : on enregistre d'abord un fichier brut provisoire, filtré à la fin.
            filtreEnregistre = filtre
            let u = Dossiers.nouveauFichier(filtre == .aucun ? "Enregistrement caméra" : "Enregistrement caméra (sans filtre)", ext: "mov")
            fichierEnCours = u
            sortieFilm.startRecording(to: u, recordingDelegate: self)
            commence()
        case .audio:
            let u = Dossiers.nouveauFichier("Enregistrement audio", ext: "m4a")
            fichierEnCours = u
            sortieAudio.audioSettings = qualiteAudio.reglagesAudio
            sortieAudio.startRecording(to: u, outputFileType: .m4a, recordingDelegate: self)
            commence()
        }
    }

    private func commence() { enCours = true; debut = Date() }

    private func arreter() {
        switch mode {
        case .camera: sortieFilm.stopRecording()
        case .audio: sortieAudio.stopRecording()
        }
    }

    fileprivate func termine(_ url: URL?, erreur: Error?) {
        guard enCours else { return }
        enCours = false; debut = nil
        fichierEnCours = nil
        if let url, FileManager.default.fileExists(atPath: url.path), filtreEnregistre != .aucun, mode == .camera {
            appliquerFiltre(brut: url)
        } else if let url, FileManager.default.fileExists(atPath: url.path) {
            Fenetres.partage.ouvrir(url)
        } else if let erreur {
            message = "L'enregistrement a échoué : \(erreur.localizedDescription)"
        }
    }

    /// Applique le filtre de couleur au fichier brut (export ffmpeg, avec sa fenêtre de progression),
    /// puis ouvre le résultat. Si tout s'est bien passé, le fichier sans filtre part à la Corbeille
    /// (récupérable) ; sinon il reste dans le dossier des enregistrements.
    private func appliquerFiltre(brut: URL) {
        var m = Montage(); m.filtre = filtreEnregistre
        let format = qualiteVideo.formatFiltre
        let dest = Dossiers.nouveauFichier("Enregistrement caméra \(filtreEnregistre.titre)", ext: format.extensionFichier)
        let t = TacheExport(source: brut, dest: dest, format: format, montage: m)
        t.apresSucces = { final in
            try? FileManager.default.trashItem(at: brut, resultingItemURL: nil)
            Fenetres.partage.ouvrir(final)
        }
        MoteurVLC.trace("enregistrement : filtre \(filtreEnregistre.titre) appliqué → \(dest.lastPathComponent)")
        Fenetres.partage.ouvrirExport(t)
    }

    /// Arrêt complet de la caméra et du micro, AVANT que la fenêtre ne démonte l'aperçu : si l'aperçu
    /// est détruit pendant que la session s'arrête sur une autre file, les deux peuvent s'attendre
    /// mutuellement et l'app se fige (constaté à la fermeture d'un enregistrement, 21/11/2026).
    func fermer() {
        if enCours { arreter() }
        fileSession.sync {}   // attend une éventuelle reconfiguration en cours
        if session.isRunning { session.stopRunning() }
        MoteurVLC.trace("enregistrement : caméra et micro arrêtés")
    }

    /// L'enregistreur de la fenêtre ouverte (une seule fenêtre d'enregistrement à la fois).
    static weak var courant: Enregistreur?
}

extension Enregistreur: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // Une erreur « arrêt normal » accompagne parfois un fichier valide.
        Task { @MainActor in self.termine(url, erreur: error) }
    }
}

// MARK: - Vue

struct ApercuCamera: NSViewRepresentable {
    let session: AVCaptureSession
    let filtre: Filtre
    func makeNSView(context: Context) -> NSView {
        let v = VueNoire()
        v.layerUsesCoreImageFilters = true   // aperçu du filtre de couleur en direct
        let couche = AVCaptureVideoPreviewLayer(session: session)
        couche.videoGravity = .resizeAspect
        couche.frame = v.bounds
        couche.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer?.addSublayer(couche)
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        v.layer?.sublayers?.first { $0 is AVCaptureVideoPreviewLayer }?.filters = filtre.filtresCouche
    }
}

struct VueEnregistrement: View {
    @StateObject private var e: Enregistreur
    init(mode: ModeEnregistrement) {
        let en = Enregistreur()
        en.mode = mode
        _e = StateObject(wrappedValue: en)
    }

    /// Taille de la fenêtre : au-delà d'un seuil, bande d'aperçus des filtres et réglages en clair.
    @State private var taille = CGSize.zero
    private var large: Bool { taille.width >= 900 && taille.height >= 600 }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $e.mode) {
                ForEach(ModeEnregistrement.allCases) { m in Label(m.rawValue, systemImage: m.icone).tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(e.enCours)
            .padding(12)

            ZStack {
                switch e.mode {
                case .camera: ApercuCamera(session: e.session, filtre: e.filtre)
                case .audio:
                    VStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 48)).foregroundStyle(.secondary)
                        Text("Enregistrement audio (fichier .m4a) · \(e.qualiteAudio.detailAudio)").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(e.mode == .camera ? 1 : 0.05))

            if let m = e.message {
                Text(m).font(.callout).foregroundStyle(.red).padding(.horizontal, 12).padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if large && e.mode == .camera { bandeFiltres.padding(.top, 10) }

            HStack(spacing: 14) {
                // Réglages en clair s'ils tiennent, sinon en icônes compactes.
                ViewThatFits(in: .horizontal) {
                    reglagesDetailles
                    reglages
                }
                Spacer(minLength: 8)
                if let d = e.debut {
                    TimelineView(.periodic(from: d, by: 1)) { ctx in
                        Text(formatTemps(ctx.date.timeIntervalSince(d))).monospacedDigit()
                    }
                }
                Button(action: e.basculer) {
                    Image(systemName: e.enCours ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 34)).foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .help(e.enCours ? "Arrêter" : "Enregistrer")
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { taille = $0 }
        .onAppear { e.preparer() }
        .onDisappear { e.fermer() }
    }

    /// Réglages en icônes (avec un petit mot dessous) ; le détail est dans les menus et les bulles d'aide.
    @ViewBuilder private var reglages: some View {
        HStack(spacing: 6) {
            if e.mode == .camera {
                Menu {
                    ForEach(e.cameras, id: \.uniqueID) { c in
                        Button { e.cameraID = c.uniqueID } label: { coche(c.localizedName, e.cameraID == c.uniqueID) }
                    }
                } label: { Reglage(icone: "video", mot: "Caméra") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Caméra : \(e.cameras.first { $0.uniqueID == e.cameraID }?.localizedName ?? "aucune")")

                // macOS ouvre le même panneau (Centre de contrôle) pour les effets caméra et les modes micro :
                // un seul bouton, pour ne pas faire croire à deux réglages différents.
                Button { AVCaptureDevice.showSystemUserInterface(.videoEffects) } label: { Reglage(icone: "wand.and.stars", mot: "Effets") }
                    .buttonStyle(.plain)
                    .help("Effets de macOS : mode Studio, Portrait, Cadre centré, Arrière-plan… et Isolation de la voix pour le micro")

                Menu {
                    ForEach(Filtre.allCases) { f in
                        Button { e.filtre = f } label: { coche(f.titre, e.filtre == f) }
                    }
                } label: { Reglage(icone: "camera.filters", mot: e.filtre == .aucun ? "Filtre" : e.filtre.titre, actif: e.filtre != .aucun) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Filtre de couleur : visible dès maintenant, appliqué au fichier à la fin de l'enregistrement")

                MenuQualite(choix: $e.qualiteVideo, video: true)
            } else {
                MenuQualite(choix: $e.qualiteAudio, video: false)
            }

            Menu {
                ForEach(e.micros, id: \.uniqueID) { m in
                    Button { e.microID = m.uniqueID } label: { coche(m.localizedName, e.microID == m.uniqueID) }
                }
            } label: { Reglage(icone: "mic", mot: "Micro") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Micro : \(e.micros.first { $0.uniqueID == e.microID }?.localizedName ?? "aucun")")

            if e.mode == .audio {
                Button { AVCaptureDevice.showSystemUserInterface(.microphoneModes) } label: { Reglage(icone: "waveform.badge.mic", mot: "Mode micro") }
                    .buttonStyle(.plain)
                    .help("Isolation de la voix, spectre large (réglages de macOS)")
            }
        }
        .disabled(e.enCours)
    }

    /// Bande d'aperçus : l'image de la caméra avec chaque filtre (fenêtre large).
    private var bandeFiltres: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Filtre.allCases) { f in
                    Button { e.filtre = f } label: {
                        VStack(spacing: 4) {
                            Group {
                                if let i = e.image { Image(nsImage: f.apercu(i)).resizable().aspectRatio(contentMode: .fill) }
                                else { Rectangle().fill(Color.gray.opacity(0.25)) }
                            }
                            .frame(width: 112, height: 63).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(e.filtre == f ? Color.yellow : Color.clear, lineWidth: 2.5))
                            Text(f.titre).font(.caption2)
                                .foregroundStyle(e.filtre == f ? Color.yellow : Color.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .disabled(e.enCours)
    }

    /// Réglages en clair (fenêtre assez large) : noms des appareils, qualité en trois cases avec son usage.
    @ViewBuilder private var reglagesDetailles: some View {
        HStack(spacing: 16) {
            if e.mode == .camera {
                Picker(selection: $e.cameraID) {
                    ForEach(e.cameras, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
                } label: { Image(systemName: "video") }
                .frame(width: 190)
                Button { AVCaptureDevice.showSystemUserInterface(.videoEffects) } label: { Label("Effets", systemImage: "wand.and.stars") }
                    .help("Effets de macOS : mode Studio, Portrait, Cadre centré, Arrière-plan… et Isolation de la voix pour le micro")
                if !large {
                    Menu {
                        ForEach(Filtre.allCases) { f in Button { e.filtre = f } label: { coche(f.titre, e.filtre == f) } }
                    } label: { Label(e.filtre == .aucun ? "Filtre" : e.filtre.titre, systemImage: "camera.filters") }
                    .fixedSize()
                }
                choixQualite($e.qualiteVideo, video: true)
            } else {
                choixQualite($e.qualiteAudio, video: false)
            }
            Picker(selection: $e.microID) {
                ForEach(e.micros, id: \.uniqueID) { Text($0.localizedName).tag(Optional($0.uniqueID)) }
            } label: { Image(systemName: "mic") }
            .frame(width: 190)
            if e.mode == .audio {
                Button { AVCaptureDevice.showSystemUserInterface(.microphoneModes) } label: { Label("Mode micro", systemImage: "waveform.badge.mic") }
            }
        }
        .fixedSize()
        .disabled(e.enCours)
    }

    private func choixQualite(_ q: Binding<Qualite>, video: Bool) -> some View {
        VStack(spacing: 3) {
            Picker("", selection: q) {
                ForEach(Qualite.allCases) { Text($0.titre).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            Text(video ? q.wrappedValue.usageVideo : q.wrappedValue.usageAudio)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(video ? q.wrappedValue.detailVideo : q.wrappedValue.detailAudio)
    }

    @ViewBuilder private func coche(_ t: String, _ oui: Bool) -> some View {
        if oui { Label(t, systemImage: "checkmark") } else { Text(t) }
    }
}

/// Un réglage de la barre d'enregistrement : grande icône, petit mot dessous (jaune quand il est actif).
struct Reglage: View {
    let icone: String
    let mot: String
    var actif = false
    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: icone).font(.system(size: 19)).frame(height: 22)
            Text(mot).font(.system(size: 10)).lineLimit(1)
        }
        .foregroundStyle(actif ? Color.yellow : Color.primary)
        .frame(minWidth: 54)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// Choix de la qualité, avec l'usage conseillé et le poids de chaque option.
struct MenuQualite: View {
    @Binding var choix: Qualite
    let video: Bool

    var body: some View {
        Menu {
            ForEach(Qualite.allCases) { q in
                Button { choix = q } label: {
                    let texte = "\(q.titre) — \(video ? q.usageVideo : q.usageAudio)"
                    if choix == q { Label(texte, systemImage: "checkmark") } else { Text(texte) }
                    Text(video ? q.detailVideo : q.detailAudio)
                }
            }
        } label: {
            Reglage(icone: "dial.medium", mot: "Qualité : \(choix.titre)")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("\(choix.titre) — \(video ? choix.usageVideo : choix.usageAudio)\n\(video ? choix.detailVideo : choix.detailAudio)")
    }
}
