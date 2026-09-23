<div align="center">
  <img src="./docs/logo.png" alt="Paste Lite" width="112" height="112" />

  <h1>Paste Lite</h1>

  <p><strong>A lightweight, native clipboard manager for macOS.</strong></p>

  <p>English | <a href="./README.zh-CN.md">简体中文</a></p>

  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="macOS 14 or later" />
    <img src="https://img.shields.io/badge/SwiftUI-native-F05138?style=flat-square&amp;logo=swift&amp;logoColor=white" alt="Native SwiftUI" />
    <img src="https://img.shields.io/badge/storage-local-6366F1?style=flat-square" alt="Local storage" />
    <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-22C55E?style=flat-square" alt="MIT license" /></a>
  </p>

  <p><a href="#getting-started">Getting started</a> · <a href="./CONTRIBUTING.md">Contributing</a> · <a href="./CHANGELOG.md">Changelog</a></p>
</div>

## About

Paste Lite keeps your clipboard history within reach from the macOS menu bar. Open it with **⇧⌘V**, find something you copied, and reuse it in your current app.

Built with SwiftUI, AppKit, and SwiftData, it stores history on your Mac without an account, cloud sync, or telemetry. The app currently uses a Simplified Chinese interface; project documentation is available in English and Chinese.

## Features

- **Clipboard history** — save plain text, links, images, and file references; repeated content is deduplicated.
- **Quick search** — search content, filenames, and source apps, with filters for content type and application.
- **Image previews** — browse thumbnails and expand a side panel for images, text, links, or file paths.
- **Keyboard access** — open history with ⇧⌘V, navigate with arrow keys, and reuse the first nine results with ⌘1–9.
- **Return to your app** — double-click a result or press Return to copy it and attempt a paste into the previous application. Automatic pasting requires Accessibility permission.
- **Native presentation** — a menu bar app with no Dock icon, system light/dark appearance, date groups, and time labels calculated when the panel opens.
- **Local storage** — history and captured images stay on disk; clipboard monitoring pauses during sleep and inactive user sessions.

Single image files also appear under the image filter, while retaining their file format when copied back to the clipboard.

## Getting started

### Requirements

- macOS 14 or later to run the app.
- Xcode 26 or later to build it, including the native `.icon` asset.

### Build from source

Download or clone this repository, then run the following from its root directory:

```bash
xcodebuild \
  -project PasteLite.xcodeproj \
  -scheme PasteLite \
  -configuration Release \
  -derivedDataPath .build \
  build

open ".build/Build/Products/Release/Paste Lite.app"
```

To install, quit any running copy of Paste Lite, then copy `.build/Build/Products/Release/Paste Lite.app` into **Applications** in Finder. Launch the installed copy. For development and tests, see [Contributing](./CONTRIBUTING.md).

### Usage

| Action | Shortcut or interaction |
| --- | --- |
| Open / close history | ⇧⌘V or the menu bar menu |
| Select a result | Click or ↑ / ↓ |
| Copy and attempt to paste a result | Double-click or Return |
| Reuse one of the first nine filtered results | ⌘1–9 |
| Close the panel | Esc |
| Toggle the preview panel | Sidebar button next to the source filter |

Selecting a row does not paste or automatically scroll the list. Without Accessibility permission, a paste action still copies the result to the clipboard; return to the destination app and press **⌘V** manually.

## Accessibility permission

Use **Open Settings** (`打开设置`) in the history panel, or go to **System Settings → Privacy & Security → Accessibility**, then enable Paste Lite. If it is missing, add `/Applications/Paste Lite.app` with the **+** button.

**Known issue:** permission detection can still report “not authorized” even with the system switch enabled. This remains unresolved. Restarting the app or removing and re-adding the installed app may help, but is not a confirmed fix. The project currently uses ad-hoc signing, so replacing a build can also invalidate a previous grant. Manual copying and ⌘V remain available.

## Data and privacy

History is stored in `~/Library/Application Support/PasteLite/`. Files are stored as references to their original paths, not as backups; moving or deleting an original file can make that entry unavailable.

- The clipboard is checked every two seconds, so very rapid consecutive copies may not all be captured.
- History is limited to 1,000 entries and 500 MiB of recorded payload. This is not a total disk-usage cap; database overhead and thumbnails are additional.
- Plain text is limited to 2 MiB and stored PNG images to 25 MiB each.
- Clipboard entries marked concealed, transient, or automatically generated are skipped. Unmarked passwords or other sensitive text are not automatically detected.
- Storage is local, but is not encrypted by the app. Protect it as you would other personal files.

## Contributing

Bug reports, focused pull requests, and documentation improvements are welcome. Read the [contribution guide](./CONTRIBUTING.md) for setup, architecture, and validation steps. See the [changelog](./CHANGELOG.md) for project changes.

## License

Paste Lite is available under the [MIT License](./LICENSE).
