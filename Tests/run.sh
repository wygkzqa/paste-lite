#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# TEST_ARCH=x86_64 exercises the Intel build under Rosetta on Apple silicon.
TEST_ARCH="${TEST_ARCH:-$(uname -m)}"
case "$TEST_ARCH" in
  arm64|x86_64) ;;
  *) echo "Unsupported TEST_ARCH: $TEST_ARCH" >&2; exit 1 ;;
esac
compile() {
  xcrun swiftc -target "${TEST_ARCH}-apple-macosx14.0" "$@"
}

mkdir -p .build/tests
cp -R PasteLite/Resources/en.lproj PasteLite/Resources/zh-Hans.lproj .build/tests/
compile -parse-as-library -module-name PasteLiteImageTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift \
  PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift \
  PasteLite/Services/ClipboardMonitor.swift \
  PasteLite/Services/PasteService.swift \
  PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift \
  PasteLite/UI/ClipboardImageLoader.swift \
  Tests/ClipboardImageTests.swift \
  -o .build/tests/clipboard-images
.build/tests/clipboard-images

compile -parse-as-library -module-name PasteLiteURLTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/Services/ClipboardMonitor.swift PasteLite/Services/PasteService.swift \
  Tests/ClipboardURLTests.swift -o .build/tests/clipboard-urls
.build/tests/clipboard-urls

compile -parse-as-library -module-name PasteLiteImportTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift \
  PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift \
  PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/PasteImportView.swift \
  Tests/PasteImportTests.swift \
  -o .build/tests/paste-import
.build/tests/paste-import

compile -parse-as-library -module-name PasteLiteLanguageTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift \
  PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift \
  PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift \
  Tests/LanguageSettingsTests.swift \
  -o .build/tests/language-settings
.build/tests/language-settings

compile -parse-as-library -module-name PasteLiteLoginItemTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Services/LoginItemManager.swift \
  Tests/LoginItemTests.swift \
  -o .build/tests/login-items
.build/tests/login-items

compile -parse-as-library -module-name PasteLitePerformanceTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift \
  PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift \
  PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift \
  PasteLite/UI/ClipboardImageLoader.swift \
  Tests/Performance/Fixtures.swift Tests/PerformanceRegressionTests.swift \
  -o .build/tests/performance-regression
.build/tests/performance-regression

# Both executables intentionally use the same module name for schema identity.
compile -parse-as-library -module-name PasteLiteHistoryTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  Tests/LegacyHistoryFixture.swift -o .build/tests/legacy-history-fixture
compile -parse-as-library -module-name PasteLiteHistoryTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/HistoryLimitsTests.swift -o .build/tests/history-limits
.build/tests/history-limits

# The immediately previous schema also migrates to the new groups model.
compile -parse-as-library -module-name PasteLiteHistoryTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  Tests/PreGroupHistoryFixture.swift -o .build/tests/pre-group-history-fixture
compile -parse-as-library -module-name PasteLiteHistoryTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/ClipboardGroupTests.swift -o .build/tests/clipboard-groups
.build/tests/clipboard-groups

compile -parse-as-library -module-name PasteLiteClearHistoryTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/Services/ClipboardMonitor.swift PasteLite/UI/ClipboardViewModel.swift \
  PasteLite/UI/ClipboardImageLoader.swift Tests/Performance/Fixtures.swift \
  Tests/ClearHistoryTests.swift -o .build/tests/clear-history
.build/tests/clear-history

# Frozen schema with groups, before titles; module identity must match the reader.
compile -parse-as-library -module-name PasteLiteTitleTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  Tests/PreTitleHistoryFixture.swift -o .build/tests/pre-title-history-fixture
compile -parse-as-library -module-name PasteLiteTitleTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/Services/ClipboardMonitor.swift PasteLite/Services/PasteService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/ClipboardTitleTests.swift -o .build/tests/clipboard-titles
.build/tests/clipboard-titles

compile -parse-as-library -module-name PasteLiteEditTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/Services/ClipboardMonitor.swift PasteLite/Services/PasteService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/ClipboardEditTests.swift -o .build/tests/clipboard-edit
.build/tests/clipboard-edit

compile -parse-as-library -module-name PasteLiteTerminationTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  Tests/Performance/Fixtures.swift Tests/ClipboardTerminationTests.swift -o .build/tests/clipboard-termination
.build/tests/clipboard-termination

compile -parse-as-library -module-name PasteLiteSelectionTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/ClipboardSelectionTests.swift -o .build/tests/clipboard-selection
.build/tests/clipboard-selection

compile -parse-as-library -module-name PasteLiteSearchTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/ClipboardSearchTests.swift -o .build/tests/clipboard-search
.build/tests/clipboard-search

compile -parse-as-library -module-name PasteLitePanelTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/ClipboardMonitor.swift \
  PasteLite/Services/PasteService.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/Clipboard*.swift \
  Tests/PanelDismissalTests.swift -o .build/tests/panel-dismissal
.build/tests/panel-dismissal
