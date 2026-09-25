#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Build both slices regardless of the Mac running this script.
xcodebuild -project PasteLite.xcodeproj -scheme PasteLite \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath .build/release-build \
  SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}" build

app='.build/release-build/Build/Products/Release/Paste Lite.app'
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
case "$version" in
  ''|*[!0-9.]*) echo "Invalid release version: $version" >&2; exit 1 ;;
esac
lipo "$app/Contents/MacOS/PasteLite" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$app"
test -f "$app/Contents/Resources/Sparkle-LICENSE.txt"

output=".build/releases/$version"
mkdir -p "$output"
staging=$(mktemp -d "$output/staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT HUP INT TERM
ditto "$app" "$staging/Paste Lite.app"
ln -s /Applications "$staging/Applications"
cp LICENSE "$staging/LICENSE.txt"

filename="Paste-Lite-$version-universal.dmg"
# hdiutil refuses to overwrite a previously packaged release.
hdiutil create -volname "Paste Lite $version" -srcfolder "$staging" \
  -format UDZO "$output/$filename"
hdiutil verify "$output/$filename"
(cd "$output" && shasum -a 256 "$filename" > SHA256SUMS.txt)
printf 'Release files: %s/%s and %s/SHA256SUMS.txt\n' "$output" "$filename" "$output"
printf 'The project currently uses ad-hoc signing; this script does not notarize or publish.\n'
