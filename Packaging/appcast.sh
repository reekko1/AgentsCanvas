#!/bin/bash
# Add the just-packaged release to docs/appcast.xml — the feed Sparkle checks.
# Run AFTER Packaging/package.sh, then commit docs/appcast.xml and upload the
# zip to the matching GitHub release (tag v<version>):
#
#   Packaging/appcast.sh
#   git add docs/appcast.xml && git commit
#   gh release create v<version> dist/AgentCanvas-<version>.zip dist/AgentCanvas-<version>.dmg
#
# Reads version + build straight from the built app (single source of truth)
# and signs the zip with the Sparkle EdDSA key from the login keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/Agent Canvas.app"
[ -d "$APP" ] || { echo "✗ $APP not found — run Packaging/package.sh first" >&2; exit 1; }

VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
BUILD="$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")"
ZIP="dist/AgentCanvas-$VERSION.zip"
[ -f "$ZIP" ] || { echo "✗ $ZIP not found" >&2; exit 1; }

SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
[ -x "$SIGN_UPDATE" ] || { echo "✗ sign_update missing — run swift build once" >&2; exit 1; }

URL="https://github.com/reekko1/AgentsCanvas/releases/download/v$VERSION/AgentCanvas-$VERSION.zip"
APPCAST="docs/appcast.xml"

# sign_update emits the ready-made attribute pair: sparkle:edSignature="…" length="…"
SIG_ATTRS="$("$SIGN_UPDATE" "$ZIP")"
PUBDATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

mkdir -p docs
if [ ! -f "$APPCAST" ]; then
    cat > "$APPCAST" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Agent Canvas</title>
    <description>Updates for Agent Canvas</description>
    <language>en</language>
    <!-- items -->
  </channel>
</rss>
XML
fi

if grep -q "<sparkle:shortVersionString>$VERSION<" "$APPCAST"; then
    echo "✗ $VERSION is already in the appcast — bump VERSION and repackage" >&2
    exit 1
fi

# Newest first: insert directly under the marker (sed r — BSD awk can't take
# multiline -v strings).
ITEM_FILE="$(mktemp)"
cat > "$ITEM_FILE" <<ITEM
    <item>
      <title>Agent Canvas $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="$URL" $SIG_ATTRS type="application/octet-stream"/>
    </item>
ITEM
sed "/<!-- items -->/r $ITEM_FILE" "$APPCAST" > "$APPCAST.tmp"
mv "$APPCAST.tmp" "$APPCAST"
rm -f "$ITEM_FILE"
xmllint --noout "$APPCAST"

echo "▸ appcast updated: $APPCAST"
echo "  $VERSION (build $BUILD) → $URL"
echo "  remember: commit docs/appcast.xml + upload $ZIP to release v$VERSION"
