# Changelog

English | [简体中文](./CHANGELOG.zh-CN.md)

User-visible changes are recorded here. The current source reports version **1.0 (build 10)**; this is a local development version, not a published release.

## Unreleased

### Added

- Native macOS menu bar application built with SwiftUI and AppKit, targeting macOS 14 and later.
- Local clipboard history for text, links, images, and file references, with deduplication and SwiftData persistence.
- Global ⇧⌘V shortcut, keyboard navigation, ⌘1–9 actions, and automatic paste support when Accessibility permission is available.
- Keyword search and filters by content type and source app.
- Image thumbnails, an optional content preview panel, and date-grouped history.
- Background image processing and storage, bounded history retention, and monitoring that pauses during sleep and inactive sessions.
- Native application icon, a separate menu bar icon, and an About window with logo, version, and build number.
- Isolated image regression tests, bilingual project documentation, and an MIT license.

### Changed

- Standardized the displayed app name to **Paste Lite**, preserving the `PasteLite` module and existing data directory.
- Calculate segmented time labels once when opening history instead of continuously updating them.
- Select rows immediately on click and remove automatic list scrolling; double-click remains a paste action.
- Show single image-file references in image filters and previews while preserving file paste behavior.
- Open Accessibility settings directly from the permission banner and recheck permission when returning to the app or reopening history.

### Known issues

- Accessibility authorization may still be reported as unavailable even with the system switch enabled. This remains unresolved; manual ⌘V after copying is the fallback.
- Ad-hoc signing can invalidate previous permission grants when the application is replaced with a new build.
- The app interface is currently Simplified Chinese only.
