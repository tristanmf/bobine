#!/bin/bash
#
# construire-app.sh — compile l'app « Bobine » et l'installe dans ~/Applications.
# Prompté par Tristan Mendès France — https://tristan.pro
#
# Prérequis (une fois) : outils Xcode (xcode-select --install), VLC dans /Applications,
# ffmpeg (brew install ffmpeg). Puis :  bash construire-app.sh
#
set -e
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "⚠️  Le compilateur Swift est absent. Terminal :  xcode-select --install"
  exit 1
fi
[ -d /Applications/VLC.app ] || echo "⚠️  VLC absent de /Applications : seuls les formats Apple seront lus."
command -v ffmpeg >/dev/null 2>&1 || [ -x /opt/homebrew/bin/ffmpeg ] || echo "⚠️  ffmpeg absent : l'export ne marchera pas (brew install ffmpeg)."

echo ">>> Compilation…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/Bobine"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/Bobine.app"
mkdir -p "$APP_DIR"

echo ">>> Assemblage de l'app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bobine"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Bobine</string>
    <key>CFBundleIdentifier</key><string>pro.tristan.bobine</string>
    <key>CFBundleName</key><string>Bobine</string>
    <key>CFBundleDisplayName</key><string>Bobine</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>fr</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Tristan Mendès France</string>
    <key>NSCameraUsageDescription</key><string>Bobine utilise la caméra pour les enregistrements vidéo.</string>
    <key>NSMicrophoneUsageDescription</key><string>Bobine utilise le micro pour les enregistrements vidéo et audio.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Vidéo ou audio</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.audiovisual-content</string>
                <string>public.audio</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Vidéo (formats VLC)</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>mkv</string><string>webm</string><string>avi</string><string>flv</string>
                <string>wmv</string><string>ogv</string><string>ogg</string><string>ts</string>
                <string>m2ts</string><string>mts</string><string>vob</string><string>divx</string>
                <string>3gp</string><string>rm</string><string>rmvb</string><string>asf</string>
                <string>mpg</string><string>mpeg</string><string>flac</string><string>opus</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

if [ -f "AppIcon.png" ]; then
  echo ">>> Génération de l'icône…"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for taille in 16 32 128 256 512; do
    double=$((taille * 2))
    sips -z "$taille" "$taille" AppIcon.png --out "$ICONSET/icon_${taille}x${taille}.png"   >/dev/null 2>&1
    sips -z "$double" "$double" AppIcon.png --out "$ICONSET/icon_${taille}x${taille}@2x.png" >/dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || echo "    ⚠️  icône non générée"
  rm -rf "$(dirname "$ICONSET")"
fi

# Signature ad hoc (usage local). Pas de sandbox : l'app charge le moteur de VLC et lance ffmpeg.
# Le moteur VLC est signé par VideoLAN : on désactive la vérification de bibliothèque pour pouvoir le charger.
cat > "$(dirname "$BIN")/bobine.entitlements" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.disable-library-validation</key><true/>
  <key>com.apple.security.device.camera</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
</dict></plist>
ENT
codesign --force --sign - --entitlements "$(dirname "$BIN")/bobine.entitlements" "$APP" >/dev/null 2>&1 || true

# Enregistre l'app auprès du Finder (menu « Ouvrir avec »).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo ""
echo "============================================================"
echo " ✅ App installée :  $APP"
echo "    Pour en faire le lecteur par défaut d'un format : clic droit sur un fichier"
echo "    › Lire les informations › Ouvrir avec : Bobine › Tout modifier."
echo "============================================================"
