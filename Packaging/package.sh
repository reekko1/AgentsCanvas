#!/bin/bash
# Build a distributable "Agent Canvas.app" (+ zip) from the SPM tree — no Xcode
# project, in keeping with the repo. Output lands in dist/.
#
#   Packaging/package.sh                  # ad-hoc signed (runs fine locally;
#                                         # downloads still hit Gatekeeper)
#   CODESIGN_IDENTITY="Developer ID Application: …" Packaging/package.sh
#                                         # real signing, ready for notarization
#   CODESIGN_IDENTITY="…" NOTARY_PROFILE=canvas-notary Packaging/package.sh
#                                         # + notarize, staple, re-zip: the full
#                                         # release artifact, double-click clean
#   VERSION=0.2.0 Packaging/package.sh    # bump CFBundleShortVersionString
#                                         # (update checks compare against it)
#   DMG=1 …                               # also build the drag-to-install disk
#                                         # image (first-install artifact; the
#                                         # zip remains the Sparkle artifact)
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Agent Canvas"
VERSION="${VERSION:-0.1.0}"
BUNDLE_ID="${BUNDLE_ID:-com.rakan.agentcanvas}"
IDENTITY="${CODESIGN_IDENTITY:--}"   # "-" = ad-hoc

# Sparkle update metadata. CFBundleVersion must rise monotonically — the commit
# count does that for free. The public key's private half lives in the login
# keychain ("Private key for signing Sparkle updates", created by generate_keys).
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
FEED_URL="${SU_FEED_URL:-https://raw.githubusercontent.com/reekko1/AgentsCanvas/main/docs/appcast.xml}"
ED_PUBLIC_KEY="D5g3ap4tidnDbXBCLF8q6JldD5eZC4bqM8Df9dnOkU8="

# Universal when the toolchain allows; native otherwise. (The dual-arch path
# builds through Xcode's build system, which needs the Metal toolchain for
# SwiftTerm's shaders — `xcodebuild -downloadComponent MetalToolchain` enables
# it. Apple Silicon-only is fine for sharing in practice.)
echo "▸ building release…"
if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    PRODUCTS=".build/apple/Products/Release"
    echo "  universal (arm64 + x86_64)"
else
    swift build -c release
    PRODUCTS=".build/release"
    echo "  native ($(uname -m) only)"
fi

DIST="dist"
APP="$DIST/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$PRODUCTS/AgentCanvas" "$APP/Contents/MacOS/AgentCanvas"
# The SPM resource bundle (fonts + backdrop videos): Bundle.module resolves it
# through Bundle.main.resourceURL, so it lives in Contents/Resources verbatim.
cp -R "$PRODUCTS/AgentCanvas_AgentCanvas.bundle" "$APP/Contents/Resources/"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sparkle: embed the framework and point the binary at Contents/Frameworks
# (the SPM link leaves only @loader_path + build-machine rpaths).
mkdir -p "$APP/Contents/Frameworks"
SPARKLE_FW="$PRODUCTS/Sparkle.framework"
[ -d "$SPARKLE_FW" ] || SPARKLE_FW=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/AgentCanvas"
# Shipped binaries shouldn't advertise this Mac's toolchain paths.
otool -l "$APP/Contents/MacOS/AgentCanvas" | awk '/LC_RPATH/{f=1} f && /path /{print $2; f=0}' \
    | grep -E 'Xcode|\.build|Toolchains' | while read -r rp; do
    install_name_tool -delete_rpath "$rp" "$APP/Contents/MacOS/AgentCanvas" 2>/dev/null || true
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>      <string>en</string>
    <key>CFBundleExecutable</key>             <string>AgentCanvas</string>
    <key>CFBundleIconFile</key>               <string>AppIcon</string>
    <key>CFBundleIdentifier</key>             <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>  <string>6.0</string>
    <key>CFBundleName</key>                   <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>            <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>            <string>APPL</string>
    <key>CFBundleShortVersionString</key>     <string>${VERSION}</string>
    <key>CFBundleVersion</key>                <string>${BUILD}</string>
    <key>LSMinimumSystemVersion</key>         <string>13.0</string>
    <key>SUFeedURL</key>                      <string>${FEED_URL}</string>
    <key>SUPublicEDKey</key>                  <string>${ED_PUBLIC_KEY}</string>
    <key>LSApplicationCategoryType</key>      <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>        <true/>
    <key>NSHumanReadableCopyright</key>       <string>© $(date +%Y) Rakan Alyahya</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" > /dev/null

# Hardened runtime so the identical command notarizes cleanly once a real
# identity is supplied; harmless under ad-hoc. Sparkle (with its nested XPC
# services + updater helper) is re-signed under our identity first — hardened
# runtime enforces library validation, which rejects frameworks from other teams.
echo "▸ signing ($([ "$IDENTITY" = "-" ] && echo ad-hoc || echo "$IDENTITY"))…"
codesign --force --options runtime --deep --sign "$IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --deep --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

ZIP="$DIST/AgentCanvas-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# Notarize + staple when a notary profile is supplied (needs a real identity —
# Apple rejects ad-hoc). Store credentials once with:
#   xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password <app-specific>
if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ "$IDENTITY" = "-" ]; then
        echo "✗ NOTARY_PROFILE set but signing is ad-hoc — set CODESIGN_IDENTITY" >&2
        exit 1
    fi
    echo "▸ notarizing (waits on Apple, typically 1–5 min)…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # re-zip so the download carries the ticket
    spctl -a -vv "$APP"
fi

# DMG=1 → a presentation disk image for first installs (the zip stays the
# Sparkle-update artifact). Built after notarization so it carries the stapled
# app; the DMG itself is then signed (+ notarized/stapled when a profile is set)
# so Gatekeeper trusts it at mount time.
DMG_PATH=""
if [ -n "${DMG:-}" ]; then
    command -v create-dmg > /dev/null || { echo "✗ create-dmg not found (brew install create-dmg)" >&2; exit 1; }
    echo "▸ building dmg…"
    STAGE="$(mktemp -d)"
    cp -R "$APP" "$STAGE/"
    DMG_PATH="$DIST/AgentCanvas-$VERSION.dmg"
    rm -f "$DMG_PATH"
    create-dmg \
        --volname "$APP_NAME" \
        --volicon Packaging/AppIcon.icns \
        --background Packaging/dmg-background.tiff \
        --window-pos 200 140 \
        --window-size 600 400 \
        --icon-size 128 \
        --icon "$APP_NAME.app" 150 185 \
        --app-drop-link 450 185 \
        --hide-extension "$APP_NAME.app" \
        --no-internet-enable \
        "$DMG_PATH" "$STAGE"
    rm -rf "$STAGE"
    codesign --force --sign "$IDENTITY" "$DMG_PATH"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        echo "▸ notarizing dmg…"
        xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG_PATH"
        spctl -a -t open --context context:primary-signature -vv "$DMG_PATH" || true
    fi
fi

echo "▸ done:"
echo "  $APP"
echo "  $ZIP"
[ -n "$DMG_PATH" ] && echo "  $DMG_PATH"
exit 0
