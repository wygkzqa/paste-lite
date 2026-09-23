#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/tests
xcrun swiftc -parse-as-library -module-name PasteLiteImageTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift \
  PasteLite/Services/ClipboardRepository.swift \
  PasteLite/Services/ClipboardMonitor.swift \
  PasteLite/Services/PasteService.swift \
  PasteLite/UI/ClipboardViewModel.swift \
  PasteLite/UI/ClipboardImageLoader.swift \
  Tests/ClipboardImageTests.swift \
  -o .build/tests/clipboard-images
.build/tests/clipboard-images
