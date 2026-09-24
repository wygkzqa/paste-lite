#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
source_dir=${1:-PasteLite}
label=${2:-after}
mkdir -p .build/performance
cp -R "$source_dir/Resources/en.lproj" "$source_dir/Resources/zh-Hans.lproj" .build/performance/
xcrun swiftc -O -parse-as-library -swift-version 5 -module-name PasteLitePerformance \
  -module-cache-path .build/ModuleCache.noindex \
  "$source_dir"/Models/*.swift \
  "$source_dir"/Services/AppSettings.swift \
  "$source_dir"/Services/ClipboardRepository.swift \
  "$source_dir"/Services/PasteImportService.swift \
  "$source_dir"/UI/ClipboardViewModel.swift \
  Tests/Performance/Fixtures.swift Tests/Performance/ModelBenchmark.swift \
  -o ".build/performance/model-$label"
".build/performance/model-$label" > ".build/performance/model-$label.jsonl"
cat ".build/performance/model-$label.jsonl"
