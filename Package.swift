// swift-tools-version:6.0
// App macOS « Bobine » — lecteur tous formats (moteur VLC) + enregistrement
// caméra / écran / audio + export en différents formats. Voir app-lecteur/README.md.
import PackageDescription

let package = Package(
    name: "Bobine",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Bobine",
            path: "Sources/Bobine"
        )
    ],
    swiftLanguageModes: [.v5]
)
