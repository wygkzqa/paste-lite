#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

# Only this local development workflow installs an app. Release packaging stays separate.
xcodebuild -project PasteLite.xcodeproj -scheme 'PasteLite Beta' \
  -configuration Beta -derivedDataPath .build build

xcrun swiftc -parse-as-library -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  scripts/install-beta.swift -o .build/install-beta
.build/install-beta '.build/Build/Products/Beta/Paste Lite Beta.app'
