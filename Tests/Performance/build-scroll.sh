#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
source_dir=${1:-PasteLite}
label=${2:-after}
app=".build/performance/Scroll-$label.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp -R "$source_dir/Resources/en.lproj" "$source_dir/Resources/zh-Hans.lproj" "$app/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Clear dict" -c "Add CFBundleIdentifier string com.local.PasteLite.Scroll.$label" -c 'Add CFBundleExecutable string ScrollBenchmark' -c 'Add CFBundleName string Paste Scroll Benchmark' -c 'Add CFBundlePackageType string APPL' -c "Add BenchmarkLabel string $label" "$app/Contents/Info.plist"
xcrun swiftc -O -parse-as-library -swift-version 5 -module-name PasteLiteScrollBenchmark \
  -module-cache-path .build/ModuleCache.noindex \
  "$source_dir"/Models/*.swift "$source_dir"/Services/*.swift "$source_dir"/UI/*.swift \
  Tests/Performance/Fixtures.swift Tests/Performance/ScrollBenchmark.swift \
  -o "$app/Contents/MacOS/ScrollBenchmark"
codesign --force --sign - "$app"
printf '%s\n' "$app"
