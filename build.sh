#!/bin/bash
# Tuneport derleme scripti
#   ./build.sh           -> derle ve build/Tuneport.app oluştur (bu Mac'in mimarisi)
#   ./build.sh install   -> derle, /Applications'a kur ve aç
#   ./build.sh test      -> protokol testlerini çalıştır (kulaklık gerekmez)
#   ./build.sh dmg       -> Apple Silicon + Intel destekli app ve dağıtım için DMG oluştur
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Tuneport.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
MODE="${1:-}"

# Canlı çeviri Apple'ın Translation çerçevesini kullanır (macOS 15+). SDK'da varsa zayıf
# bağlanır: uygulama macOS 13/14'te de açılır, çeviri yalnızca 15+'ta etkinleşir.
SDK="$(xcrun --show-sdk-path)"
EXTRA_LINK=()
if [ -d "$SDK/System/Library/Frameworks/Translation.framework" ]; then
    EXTRA_LINK=(-Xlinker -weak_framework -Xlinker Translation)
else
    echo "  (uyarı: bu SDK'da Translation yok; canlı çeviri devre dışı derlenecek)"
fi

compile() {   # $1 = mimari, $2 = çıktı
    swiftc -O -parse-as-library \
        -target "$1-apple-macos13.0" \
        -framework IOBluetooth -framework ServiceManagement -framework CoreAudio \
        -framework Speech -framework ScreenCaptureKit -framework AVFoundation \
        ${EXTRA_LINK[@]+"${EXTRA_LINK[@]}"} \
        Sources/*/*.swift \
        -o "$2"
}

# --- Testler ---
if [ "$MODE" = "test" ]; then
    mkdir -p build
    echo "▸ Testler derleniyor"
    swiftc Tests/main.swift Sources/Protocol/*.swift -o build/tests
    ./build/tests
    exit $?
fi

# --- Uygulama ---
echo "▸ Temizleniyor"
rm -rf build
rm -f Sources/App/TiniApp.swift   # yeniden adlandırma öncesinden kalan eski dosya
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "$MODE" = "dmg" ]; then
    echo "▸ Derleniyor (Apple Silicon)"
    compile arm64 build/Tuneport-arm64
    echo "▸ Derleniyor (Intel)"
    compile x86_64 build/Tuneport-x86_64
    lipo -create build/Tuneport-arm64 build/Tuneport-x86_64 -output "$APP/Contents/MacOS/Tuneport"
    rm build/Tuneport-arm64 build/Tuneport-x86_64
else
    echo "▸ Derleniyor ($(uname -m))"
    compile "$(uname -m)" "$APP/Contents/MacOS/Tuneport"
fi

echo "▸ Paketleniyor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
for f in "$APP"/Contents/Resources/*.lproj/*.strings; do plutil -lint -s "$f"; done

if [ -f Resources/AppIcon.png ]; then
    ICONSET="build/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

# Sabit bir sertifikayla imzalamak, macOS izinlerinin (Ekran Kaydı, Mikrofon) her derlemeden
# sonra yeniden sorulmasını önler. Anahtar Zinciri'nde "Tuneport Development" adlı bir kod imzalama
# sertifikası varsa o kullanılır; yoksa yerel (ad-hoc) imza atılır.
SIGN_ID="-"
if security find-identity -p codesigning 2>/dev/null | grep -q "Tuneport Development"; then
    SIGN_ID="Tuneport Development"
    echo "▸ İmzalanıyor (Tuneport Development)"
else
    echo "▸ İmzalanıyor (yerel; izinler her derlemede yeniden sorulabilir)"
fi
if ! codesign --force --deep --sign "$SIGN_ID" "$APP"; then
    echo "  ⚠️  \"$SIGN_ID\" ile imzalanamadı, yerel imzaya dönülüyor"
    codesign --force --deep --sign - "$APP"
fi
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority|Signature)=" | sed 's/^/  /'

echo "✓ Hazır: $APP"

if [ "$MODE" = "install" ]; then
    echo "▸ /Applications'a kuruluyor"
    pkill -x Tuneport 2>/dev/null || true
    pkill -x Tini 2>/dev/null || true
    # Eski sürecin tamamen kapanmasını bekle (yoksa macOS açmayı -600 hatasıyla reddedebilir)
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x Tuneport >/dev/null || break
        sleep 0.3
    done
    rm -rf /Applications/Tini.app /Applications/Tuneport.app
    cp -R "$APP" /Applications/
    open /Applications/Tuneport.app || { sleep 1; open /Applications/Tuneport.app; }
    echo "✓ Tuneport açıldı. Menü çubuğundaki kulaklık simgesine tıkla."
fi

if [ "$MODE" = "dmg" ]; then
    echo "▸ DMG oluşturuluyor"
    STAGE="build/dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    DMG="build/Tuneport-$VERSION.dmg"
    hdiutil create -volname "Tuneport" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "✓ Hazır: $DMG"
fi
