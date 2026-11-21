import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BobineApp: App {
    @NSApplicationDelegateAdaptor(Delegue.self) var delegue

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Nouvel enregistrement vidéo") { Fenetres.partage.ouvrirEnregistrement(.camera) }
                        .keyboardShortcut("n", modifiers: [.option, .command])
                    Button("Nouvel enregistrement audio") { Fenetres.partage.ouvrirEnregistrement(.audio) }
                        .keyboardShortcut("n", modifiers: [.control, .option, .command])
                    Divider()
                    Button("Ouvrir…") { Fenetres.partage.ouvrirPanneau() }
                        .keyboardShortcut("o")
                }
                CommandGroup(after: .saveItem) {
                    Button("Appliquer le montage et rouvrir") { Fenetres.partage.controleurActif?.appliquer() }
                        .keyboardShortcut("a", modifiers: [.shift, .command])
                    Menu("Exporter") {
                        ForEach(FormatExport.allCases) { f in
                            Button(f.titre) { Fenetres.partage.controleurActif?.exporter(f) }
                        }
                    }
                }
                CommandGroup(after: .toolbar) {
                    Button("Relire avec le moteur VLC") {
                        if let u = Fenetres.partage.urlActive { Fenetres.partage.ouvrir(u, forcerVLC: true) }
                    }
                    .keyboardShortcut("v", modifiers: [.shift, .command])
                }
            }
    }
}

final class Delegue: NSObject, NSApplicationDelegate {
    private var fichiersRecus = false

    func application(_ application: NSApplication, open urls: [URL]) {
        fichiersRecus = true
        Task { @MainActor in urls.forEach { Fenetres.partage.ouvrir($0) } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = MoteurVLC.partage // charge le moteur VLC dès le lancement
        // Auto-test : BOBINE_AUTOTEST_ACCUEIL=<fichier.png> → image de la fenêtre d'accueil.
        if let png = ProcessInfo.processInfo.environment["BOBINE_AUTOTEST_ACCUEIL"] {
            DispatchQueue.main.async {
                let r = ImageRenderer(content: VueAccueil()); r.scale = 1
                if let cg = r.cgImage {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: png))
                }
            }
        }
        // Sans fichier à ouvrir : la fenêtre d'accueil (filmer, enregistrer le son, ouvrir).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if !self.fichiersRecus && NSApp.windows.allSatisfy({ !$0.isVisible }) {
                Fenetres.partage.ouvrirAccueil()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Task { @MainActor in Fenetres.partage.ouvrirAccueil() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Gestion des fenêtres (AppKit) : une par fichier, une pour l'enregistrement, une par export.
@MainActor
final class Fenetres: NSObject, NSWindowDelegate {
    static let partage = Fenetres()
    private var ouvertes: [NSWindow: URL?] = [:]
    private var controleurs: [NSWindow: Controleur] = [:]
    private var derniereLecture: NSWindow?

    var controleurActif: Controleur? {
        if let k = NSApp.keyWindow, let c = controleurs[k] { return c }
        if let d = derniereLecture { return controleurs[d] }
        return nil
    }
    var urlActive: URL? { controleurActif?.url }

    func ouvrirPanneau() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.movie, .audio, .audiovisualContent, .video]
        p.allowsOtherFileTypes = true
        NSApp.activate()
        if p.runModal() == .OK { p.urls.forEach { ouvrir($0) } }
    }

    /// Fenêtre d'accueil (une seule). Elle se ferme dès qu'on ouvre un fichier ou un enregistrement.
    func ouvrirAccueil() {
        if let w = accueil { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = fenetre(titre: "Bobine", taille: NSSize(width: 760, height: 470), contenu: VueAccueil(), redimensionnable: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.isMovableByWindowBackground = true
        w.center()
        w.identifier = NSUserInterfaceItemIdentifier("accueil")
        ouvertes[w] = .some(nil)
        accueil = w
    }
    private var accueil: NSWindow?
    private func fermerAccueil() { accueil?.close(); accueil = nil }

    func ouvrir(_ url: URL, forcerVLC: Bool = false) {
        fermerAccueil()
        // Fichier déjà ouvert : on remplace sa fenêtre si on force VLC, sinon on la ramène devant.
        if let (w, _) = ouvertes.first(where: { $0.value == url }) {
            if !forcerVLC { w.makeKeyAndOrderFront(nil); return }
            w.close()
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        let c = Controleur(url: url, forcerVLC: forcerVLC)
        let w = fenetre(titre: url.lastPathComponent, taille: NSSize(width: 1000, height: 680),
                        contenu: VueLecture(c: c))
        w.representedURL = url
        ouvertes[w] = url
        controleurs[w] = c
        derniereLecture = w
    }

    func ouvrirEnregistrement(_ mode: ModeEnregistrement) {
        fermerAccueil()
        if let (w, _) = ouvertes.first(where: { $0.key.identifier?.rawValue == "enregistrement" }) {
            w.makeKeyAndOrderFront(nil); return
        }
        let w = fenetre(titre: "Enregistrement", taille: NSSize(width: 720, height: 520),
                        contenu: VueEnregistrement(mode: mode))
        w.identifier = NSUserInterfaceItemIdentifier("enregistrement")
        ouvertes[w] = .some(nil)
    }

    func ouvrirExport(_ t: TacheExport) {
        var w: NSWindow!
        w = fenetre(titre: "Export", taille: NSSize(width: 420, height: 140),
                    contenu: VueExport(t: t, fermer: { w.close() }), redimensionnable: false)
        ouvertes[w] = .some(nil)
    }

    private func fenetre<V: View>(titre: String, taille: NSSize, contenu: V, redimensionnable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if redimensionnable { style.insert(.resizable) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: taille), styleMask: style,
                         backing: .buffered, defer: false)
        w.title = titre
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: contenu)
        w.setContentSize(taille)
        // Pas plus étroit que la barre d'outils réduite (sinon ses bords sont coupés).
        if redimensionnable { w.contentMinSize = NSSize(width: min(taille.width, 720), height: min(taille.height, 420)) }
        w.delegate = self
        w.center()
        if let d = derniereLecture, d.isVisible {
            w.setFrameTopLeftPoint(NSPoint(x: d.frame.minX + 24, y: d.frame.maxY - 24))
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return w
    }

    func windowDidBecomeKey(_ n: Notification) {
        if let w = n.object as? NSWindow, let u = ouvertes[w], u != nil { derniereLecture = w }
    }

    /// Ferme la fenêtre du montage appliqué et ouvre le fichier fabriqué à la place.
    func remplacer(_ w: NSWindow?, par url: URL) {
        let cadre = w?.frame
        w?.close()
        ouvrir(url)
        if let cadre, let n = derniereLecture { n.setFrame(cadre, display: true) }
    }

    func windowWillEnterFullScreen(_ n: Notification) {
        guard let w = n.object as? NSWindow, let c = controleurs[w] else { return }
        c.terminerRecadrage(); c.modeFiltres = false; c.pleinEcran = true
    }
    func windowWillExitFullScreen(_ n: Notification) {
        if let w = n.object as? NSWindow { controleurs[w]?.pleinEcran = false }
    }

    /// Prévient avant de fermer un montage pas encore exporté.
    func windowShouldClose(_ w: NSWindow) -> Bool {
        guard let c = controleurs[w], c.montageNonExporte else { return true }
        let a = NSAlert()
        a.messageText = "Le montage n'a pas été exporté."
        a.informativeText = "Si vous fermez, les coupes de « \(c.url.lastPathComponent) » seront perdues. Le fichier original n'est pas modifié."
        a.addButton(withTitle: "Annuler")
        a.addButton(withTitle: "Fermer sans exporter")
        return a.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        controleurs[w]?.fermer()
        controleurs[w] = nil
        if w.identifier?.rawValue == "enregistrement" { Enregistreur.courant?.fermer() }
        w.contentView = nil // déclenche onDisappear → arrêt de la lecture / de la capture
        ouvertes[w] = nil
        if derniereLecture == w { derniereLecture = nil }
        if accueil == w { accueil = nil }
        // Dernière fenêtre fermée (lecture, enregistrement, export) : on revient à l'accueil, pour enchaîner.
        // Léger délai : « Appliquer » ferme une fenêtre puis en rouvre une autre aussitôt.
        if w != accueil, !(w.identifier?.rawValue == "accueil") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.ouvertes.isEmpty, NSApp.isRunning else { return }
                self.ouvrirAccueil()
            }
        }
    }
}
