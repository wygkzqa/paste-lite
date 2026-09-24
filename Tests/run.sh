#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build/tests
cp -R PasteLite/Resources/en.lproj PasteLite/Resources/zh-Hans.lproj .build/tests/
xcrun swiftc -parse-as-library -module-name PasteLiteImageTests -swift-version 5 \
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

xcrun swiftc -parse-as-library -module-name PasteLiteImportTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift \
  PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift \
  PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/PasteImportView.swift \
  Tests/PasteImportTests.swift \
  -o .build/tests/paste-import
.build/tests/paste-import

xcrun swiftc -parse-as-library -module-name PasteLiteLanguageTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift \
  PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift \
  PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift \
  Tests/LanguageSettingsTests.swift \
  -o .build/tests/language-settings
.build/tests/language-settings

xcrun swiftc -parse-as-library -module-name PasteLiteLoginItemTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Services/LoginItemManager.swift \
  Tests/LoginItemTests.swift \
  -o .build/tests/login-items
.build/tests/login-items

xcrun swiftc -parse-as-library -module-name PasteLitePerformanceTests -swift-version 5 \
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
xcrun swiftc -parse-as-library -module-name PasteLiteHistoryTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  Tests/LegacyHistoryFixture.swift -o .build/tests/legacy-history-fixture
xcrun swiftc -parse-as-library -module-name PasteLiteHistoryTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/HistoryLimitsTests.swift -o .build/tests/history-limits
.build/tests/history-limits

# The immediately previous schema also migrates to the new groups model.
xcrun swiftc -parse-as-library -module-name PasteLiteHistoryTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  Tests/PreGroupHistoryFixture.swift -o .build/tests/pre-group-history-fixture
xcrun swiftc -parse-as-library -module-name PasteLiteHistoryTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/ClipboardGroupTests.swift -o .build/tests/clipboard-groups
.build/tests/clipboard-groups

xcrun swiftc -parse-as-library -module-name PasteLiteClearHistoryTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/Services/ClipboardMonitor.swift PasteLite/UI/ClipboardViewModel.swift \
  PasteLite/UI/ClipboardImageLoader.swift Tests/Performance/Fixtures.swift \
  Tests/ClearHistoryTests.swift -o .build/tests/clear-history
.build/tests/clear-history

# Frozen schema with groups, before titles; module identity must match the reader.
xcrun swiftc -parse-as-library -module-name PasteLiteTitleTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  Tests/PreTitleHistoryFixture.swift -o .build/tests/pre-title-history-fixture
xcrun swiftc -parse-as-library -module-name PasteLiteTitleTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/Services/ClipboardMonitor.swift PasteLite/Services/PasteService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/ClipboardTitleTests.swift -o .build/tests/clipboard-titles
.build/tests/clipboard-titles

xcrun swiftc -parse-as-library -module-name PasteLiteEditTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/Services/ClipboardMonitor.swift PasteLite/Services/PasteService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/ClipboardEditTests.swift -o .build/tests/clipboard-edit
.build/tests/clipboard-edit

xcrun swiftc -parse-as-library -module-name PasteLiteSelectionTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/AppSettings.swift \
  PasteLite/Services/ClipboardRepository.swift PasteLite/Services/PasteImportService.swift \
  PasteLite/UI/ClipboardViewModel.swift Tests/Performance/Fixtures.swift \
  Tests/ClipboardSelectionTests.swift -o .build/tests/clipboard-selection
.build/tests/clipboard-selection

xcrun swiftc -parse-as-library -module-name PasteLitePanelTests -swift-version 5 \
  -module-cache-path .build/ModuleCache.noindex \
  PasteLite/Models/*.swift PasteLite/Services/*.swift PasteLite/UI/*.swift \
  Tests/PanelDismissalTests.swift -o .build/tests/panel-dismissal
.build/tests/panel-dismissal
