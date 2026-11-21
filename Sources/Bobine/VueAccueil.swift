import SwiftUI
import UniformTypeIdentifiers

/// Fenêtre d'accueil (au lancement, ou en cliquant sur l'icône du Dock sans fenêtre ouverte) :
/// trois grosses tuiles — filmer, enregistrer le son, ouvrir un fichier — et les fichiers récents.
/// On peut aussi y déposer un fichier.
struct VueAccueil: View {
    @State private var survol: Int?
    @State private var depot = false
    private let recents = Array(NSDocumentController.shared.recentDocumentURLs
        .filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(4))

    static let jaune = Color(red: 0.90, green: 1.0, blue: 0.23)
    static let corail = Color(red: 1.0, green: 0.36, blue: 0.37)
    static let menthe = Color(red: 0.35, green: 0.85, blue: 0.55)

    var body: some View {
        VStack(spacing: 26) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                Text("Bobine").font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            }
            .padding(.top, 34)

            HStack(spacing: 22) {
                tuile(0, icone: "video.fill", titre: "Filmer", detail: "Caméra · ⌥⌘N", couleur: Self.corail) {
                    Fenetres.partage.ouvrirEnregistrement(.camera)
                }
                tuile(1, icone: "mic.fill", titre: "Enregistrer le son", detail: "Micro · ⌃⌥⌘N", couleur: Self.jaune) {
                    Fenetres.partage.ouvrirEnregistrement(.audio)
                }
                tuile(2, icone: "folder.fill", titre: "Ouvrir un fichier", detail: "Vidéo ou son · ⌘O", couleur: Self.menthe) {
                    Fenetres.partage.ouvrirPanneau()
                }
            }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RÉCENTS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                    HStack(spacing: 8) {
                        ForEach(recents, id: \.self) { u in
                            Button { Fenetres.partage.ouvrir(u) } label: {
                                Label(u.deletingPathExtension().lastPathComponent, systemImage: "play.rectangle")
                                    .lineLimit(1).truncationMode(.middle)
                                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .frame(maxWidth: 170)
                                    .background(Capsule().fill(.white.opacity(0.07)))
                            }
                            .buttonStyle(.plain).help(u.path)
                        }
                    }
                }
            } else {
                Text("…ou déposez un fichier ici").font(.callout).foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .frame(width: 760, height: 470)
        .background(
            ZStack {
                LinearGradient(colors: [Color(red: 0.10, green: 0.08, blue: 0.16), Color(red: 0.03, green: 0.03, blue: 0.05)],
                               startPoint: .top, endPoint: .bottom)
                if depot { RoundedRectangle(cornerRadius: 18).stroke(Self.jaune, lineWidth: 3).padding(8) }
            }
        )
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach { Fenetres.partage.ouvrir($0) }
            return !urls.isEmpty
        } isTargeted: { depot = $0 }
    }

    private func tuile(_ i: Int, icone: String, titre: String, detail: String, couleur: Color,
                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(couleur).frame(width: 92, height: 92)
                        .shadow(color: couleur.opacity(survol == i ? 0.7 : 0.35), radius: survol == i ? 22 : 12)
                    Image(systemName: icone).font(.system(size: 38, weight: .semibold))
                        .foregroundStyle(Color(white: 0.08))
                }
                Text(titre).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white)
                Text(detail).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
            }
            .frame(width: 210, height: 220)
            .background(
                RoundedRectangle(cornerRadius: 26)
                    .fill(.white.opacity(survol == i ? 0.11 : 0.06))
                    .overlay(RoundedRectangle(cornerRadius: 26).stroke(couleur.opacity(survol == i ? 0.8 : 0.15), lineWidth: 1.5))
            )
            .scaleEffect(survol == i ? 1.04 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: survol)
            .contentShape(RoundedRectangle(cornerRadius: 26))
        }
        .buttonStyle(.plain)
        .onHover { survol = $0 ? i : (survol == i ? nil : survol) }
    }
}
