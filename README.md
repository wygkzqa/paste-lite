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

Built with SwiftUI, AppKit, and SwiftData, it stores history on your Mac without an account, cloud sync, or telemetry. The app and project documentation are available in English and Simplified Chinese.

## Features

- **Clipboard history** — save plain text, links, images, and file references; repeated content is deduplicated.
- **Import from Paste** — scan local Paste history, review counts and capacity, then import supported records and Pinboards with original times and source apps.
- **Quick search** — search content, filenames, and source apps, with filters for content type and application.
- **Image previews** — browse thumbnails and open an on-demand preview for images, text, links, or file paths.
- **Keyboard access** — open history with ⇧⌘V, navigate with arrow keys, and paste the selected item with Return.
- **Return to your app** — double-click a result or press Return to copy it and attempt a paste into the previous application. Automatic pasting requires Accessibility permission.
- **Native presentation** — a menu bar app with no Dock icon, system, light, or dark appearance and cached time labels based on when the panel opens.
- **Two compact layouts** — switch between List and Cards in Settings, with native Liquid Glass on macOS 26 and translucent materials on earlier versions.
- **Groups** — create and rename groups, assign an entry to multiple groups, and search within a group. Deleting a group keeps its history entries.
- **Launch at login** — an optional switch in Settings, managed by macOS Login Items.
- **Language settings** — follow the system by default, or choose Simplified Chinese or English; changes apply immediately and persist across launches.
- **In-app updates (1.1.1+)** — check from the menu or About page, review release notes, and confirm download and installation; optional automatic checks are off by default.
- **Local storage** — history and captured images stay on disk; clipboard monitoring pauses during sleep and inactive user sessions.

Single image files also appear under the image filter, while retaining their file format when copied back to the clipboard.

## Getting started

### Requirements

- macOS 14 or later on Apple silicon or Intel to run the app.
- Xcode 26 or later to build it, including the native `.icon` asset.

### Download and install

[Download the latest published release — macOS Universal DMG, notes and checksums](https://github.com/wygkzqa/paste-lite/releases/latest)

This source revision prepares **1.1.1 (build 13)**. Its download becomes available when the 1.1.1 Release is published; until then, the link above points to the existing 1.0.0 release.

1. Download the release's Universal DMG (`Paste-Lite-1.1.1-universal.dmg` for 1.1.1). It contains both Apple silicon (`arm64`) and Intel (`x86_64`) versions; you do not need Xcode.
2. Quit an existing copy of Paste Lite, open the disk image, and drag **Paste Lite** into **Applications**.
3. Eject the disk image, then open Paste Lite from Applications. Press **⇧⌘V** to show history.

**Signing:** the app uses ad-hoc signing and has not been notarized by Apple. Sparkle update signatures do not replace Apple code signing or notarization. Gatekeeper may block the first launch. If you trust this repository and have checked the download, follow [Apple’s instructions for opening an app from an unidentified developer](https://support.apple.com/en-us/102445). A successful local build does not imply Gatekeeper approval. Automatic pasting also has a separate [known Accessibility issue](#accessibility-permission).

For 1.1.1 and later, download the DMG, `appcast.xml`, and `SHA256SUMS.txt` from the same Release into one folder, then run `shasum -a 256 -c SHA256SUMS.txt` there. The checksum file covers both the package and update feed; 1.0.0 only needs its DMG and checksum file. CI runs regression tests on Apple Silicon and Intel macOS runners and builds the Universal package. GUI installation and online upgrades on a physical Intel Mac have not been verified.

### Online updates (1.1.1+)

In builds configured for online updates, use **Check for Updates…** in the menu bar or **Settings → About**. Review the release notes, download the update, then choose **Install and Relaunch**. Finish and close editing or import windows first. Cancelling a prepared update keeps the current version. History, groups and settings remain in place; normal retention rules still apply after restarting.

**Automatically check for updates** is off by default. When enabled, Sparkle checks about once a day and shows availability in the menu and About page without stealing focus. Downloads and installation require your action. Errors leave the current app available, and **Downloads** opens the GitHub release page.

Version 1.0.0 does not include the updater: install 1.1.1 manually once after its Release is published. Later versions can then be installed in the app. The online update source becomes available when the first signed feed is published. Source builds without a configured public update key show an explicit unavailable message; see [Contributing](./CONTRIBUTING.md#configure-online-update-publishing) for configuration. Updating does not resolve the known Accessibility authorization issue.

### Build from source

Download or clone this repository, then run the following from its root directory:

```bash
xcodebuild \
  -project PasteLite.xcodeproj \
  -scheme PasteLite \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath .build \
  build

open ".build/Build/Products/Release/Paste Lite.app"
```

To install, quit any running copy of Paste Lite, then copy `.build/Build/Products/Release/Paste Lite.app` into **Applications** in Finder. Launch the installed copy. For development and tests, see [Contributing](./CONTRIBUTING.md).

### Usage

| Action | Shortcut or interaction |
| --- | --- |
| Open / close history | ⇧⌘V or the menu bar menu |
| Open the main panel | Launch Paste Lite from Spotlight or Finder |
| Select a result | Click or ↑ / ↓ |
| Select multiple entries | ⌘-click toggles entries; ⇧-click or ⇧↑ / ⇧↓ extends a range |
| Select all matching entries | ⌘A when focus is on history, or right-click → Select All |
| Delete selected entries | Right-click → Delete…, then confirm |
| Copy and attempt to paste a result | Double-click or Return |
| Close the panel | Esc |
| Preview selected content | Right-click an entry → Preview |
| Switch layout | Layout button in the footer, or Settings → General → Clipboard Layout |
| Create or manage groups | Top `+` button / right-click a group tab → Rename or Delete Group |
| Open settings | Menu bar → Settings… or ⌘, while Paste Lite is active |

Opening Paste Lite from Spotlight or Finder shows the main panel, including when the app is already running. Login-item launches stay in the menu bar without opening the panel.

Selecting a row does not paste. Arrow-key navigation keeps the selected row visible; clicking a row does not automatically scroll the list. Without Accessibility permission, a paste action still copies the result to the clipboard; return to the destination app and press **⌘V** manually.

### Layouts and groups

Closing and reopening the panel during the same app session preserves the scroll position and selection in both layouts. New captures keep the record you were reading in place, and arrow-key navigation continues from your previous selection. This browsing state is kept in memory and resets when the app quits.

Open **Settings… → General → Clipboard Layout** to choose **List** (default) or **Cards**. The footer’s layout button also switches directly between the two, keeping your search, filters, group, and selected entry. The choice is saved, syncs with Settings, and applies immediately. Both use the same history, search, filters, and keyboard shortcuts. The glass appearance respects your chosen appearance and Reduce Transparency.

Choose **Settings… → General → Appearance** to use **System Default**, **Dark**, or **Light**. The default follows macOS. Changes apply immediately across the history panel, Settings, and app dialogs, and your choice is remembered after restarting.

Both layouts use native glass materials, with a solid fallback when Reduce Transparency is enabled. Selected entries use a blue background and white text.

Use the top **+** button to create a group. Custom groups appear as horizontally scrollable tabs alongside **All**, with a stronger selected background. There is no Ungrouped tab. Right-click a custom group tab to **Rename** or **Delete Group**; deletion requires confirmation and renaming keeps the current group filter. Use the **Add to Groups** context submenu to add or remove selected entries directly. A checkmark means all selected entries belong to the group; a dash means only some do. Choosing an unchecked or mixed group adds the selection; choosing a checked group removes that membership. **New Group…** in the context submenu creates a group and adds the selected entries. An entry can belong to multiple groups without duplicating its content. Search and type/source filters apply within the selected group. Deleting a group keeps all entries and removes only its memberships: entries without another group become ungrouped and remain visible under **All**, while other group memberships are kept. Deleting the currently selected group switches to **All**. Grouped entries follow the same retention and entry-count rules as other history.

### Settings categories

Settings uses a sidebar with **General, History, Data, and About**, with the selected options on the right. General contains language, appearance, clipboard layout, launch at login, and a Capture section for entry size limits. History controls retention and cleanup; Data contains Paste import and clear history. About shows the app logo, version, build number, a brief introduction, and the GitHub link. The menu bar’s **About Paste Lite** opens this page in the same Settings window.

### Language

Open **Settings… → General → Language** and choose **System Default**, **简体中文**, or **English**. System Default uses Simplified Chinese when the system's preferred language is Chinese (including Traditional Chinese regions), and English otherwise. Switching updates the app interface immediately without restarting or changing clipboard content, file names, source app names, or history. Settings are saved automatically.

### Launch at login

Turn on **Settings… → General → Launch at Login** to open Paste Lite when you log in to your Mac. It is off by default. The app reads the macOS login item status and refreshes it when Settings opens or the app becomes active. If approval is needed, use **Open Login Items Settings…** to allow it; failed changes show an error and retain the system status. Install Paste Lite in Applications before enabling this.

### Capture and history limits

**Settings… → General → Capture** controls the maximum text and image size. An entry equal to the limit is accepted; larger entries are skipped. Changes apply to future captures and imports, without removing existing content.

**Settings… → History** controls retention in days, maximum entry count, and cleanup interval in hours. Each defaults to 0: keep forever, unlimited entries, and no periodic cleanup. Startup still checks retention rules once. Changing a setting does not immediately delete entries, and history may temporarily exceed its count limit between cleanups. Cleanup uses creation date rather than last use, removes expired entries first, then keeps the newest entries within the count limit.

History is queried in the database, with 200 summaries per page and full text loaded for preview or paste. Search covers all stored history, including unloaded pages. It uses substring queries, not a full-text index, so large text collections can still take longer to search.

### Clear history

Choose **Settings… → Data → Clear History…** and confirm to permanently remove all Paste Lite history, including grouped records, images, thumbnails, and legacy migration backups. Groups and settings are kept. The current system clipboard and original files referenced by file records are unchanged. This cannot be undone. New copies are still recorded afterward. Image cleanup failures are reported, and you can clear again to retry.

### Selection and deletion

⌘-click adds or removes an entry, and ⇧-click selects a continuous range. Right-clicking a selected entry keeps the multi-selection; right-clicking an unselected entry selects only that entry. ⌘A selects all results under the current search, type, source, and group filters, including unloaded pages, without loading full bodies. When a text field or editor has focus, ⌘A keeps its native text-selection behavior. Changing filters clears the previous selection.

Choose **Delete…** from the context menu and confirm the entry count. Deletion removes the entries from history and all groups, and cleans up images and thumbnails that no remaining entry uses. It keeps group definitions, settings, the system clipboard, and original external files. Deletion cannot be undone. Edit and Preview are available for one selected entry.

### Edit and preview entries

Right-click a list entry or card to select it and open the context menu. **Edit…** and **Preview** use the same title-and-content form; Preview is read-only. Text and link entries support body editing, while images and files support title editing and retain their original content. ⌘Return saves, Return inserts a line break in text, and Esc cancels. Saving updates history only; the system clipboard changes when you copy or paste the entry.

Enter up to 100 characters on one line for a new title; clear it to restore the automatic title. Existing long titles imported from Paste can be preserved when editing only the body. Titles appear in both layouts and previews and participate in full-library search. Edits preserve identity, timestamps, order, source, and groups; body changes update the search summary and content deduplication. Empty text, invalid links, text above the configured size limit, and content that duplicates another entry are rejected without discarding the draft. Recopying the edited content keeps its title.

### Import from Paste

1. Let Paste finish downloading the history you want, then quit Paste.
2. Open **Settings… → Data → Import from Paste → Import…**. If needed, select the Paste data folder containing `db.sqlite` and its `.db_SUPPORT` attachments.
3. Click **Scan data** (`扫描数据`) and review new records, duplicates, skipped items, and required capacity.
4. Click **Import N records**. History is unlimited by default. If you configured an entry limit, choose **Increase entry limit and import all**, or import only recent records that fit the remaining count.

The importer recognizes the local data structure verified against **Paste 6.0.3**; other structures are rejected. It reads a database snapshot and leaves the source database and attachments unchanged. Import runs locally without Accessibility permission, network access, or writing to the system clipboard. It does not synchronize the two apps.

Text, links, PNG/TIFF/JPEG images, and accessible file references are supported. RTF is reduced to plain text; HTML requires an accompanying plain-text representation. Titles, Pinboard names (including empty boards), and record memberships are retained. For duplicate content in Paste, the most recent nonempty title is used. Imported titles are preserved in full, including those longer than the manual editor’s 100-character limit. Groups with matching names are merged case-insensitively. Content found in multiple Pinboards keeps all memberships without storing duplicate payloads. Group and item ordering, pinned status, sharing, and rich-text styles are not retained. Missing cloud content, unavailable attachments, invalid file references, and unsupported formats are counted as skipped; previews are never substituted for original images.

Existing duplicates keep their IDs, timestamps, source apps, and local group memberships; missing memberships and titles are added. Existing local titles take priority. You can use **Import groups and titles** even when all records already exist or the history entry limit is full. Groups are matched by name on each import, so renaming a destination group may create a group with the original name when importing again. Import never removes existing history to make room. An increased entry limit persists across restarts. Imported entries remain subject to the configured retention period, using their original creation dates. Capture-size changes require a fresh scan. You can cancel scanning before the final save. Repeating an import adds no duplicates.

## Accessibility permission

Use **Open Settings** (`打开设置`) in the history panel, or go to **System Settings → Privacy & Security → Accessibility**, then enable Paste Lite. If it is missing, add `/Applications/Paste Lite.app` with the **+** button.

**Known issue:** permission detection can still report “not authorized” even with the system switch enabled. This remains unresolved. Restarting the app or removing and re-adding the installed app may help, but is not a confirmed fix. The project currently uses ad-hoc signing, so replacing a build can also invalidate a previous grant. Manual copying and ⌘V remain available.

## Data and privacy

History is stored in `~/Library/Application Support/PasteLite/`. Files are stored as references to their original paths, not as backups; moving or deleting an original file can make that entry unavailable.

- The clipboard is checked every two seconds, so very rapid consecutive copies may not all be captured.
- History defaults to unlimited entries and permanent retention, without a total storage quota. Capture and retention settings are saved in `history-settings.json`. Old `limits.json` quotas no longer apply; upgrading preserves existing entries.
- Text and links default to 4 MB per entry; saved PNG images default to 100 MB. Both limits are adjustable, and 0 means unlimited. MB uses 1,024 × 1,024 bytes. File references do not copy or limit the referenced file size.
- Clipboard entries marked concealed, transient, or automatically generated are skipped. Unmarked passwords or other sensitive text are not automatically detected.
- Storage is local, but is not encrypted by the app. Protect it as you would other personal files.
- Online update checks and downloads connect to GitHub and its download infrastructure. These requests do not include clipboard content. System profiling is disabled; GitHub still receives ordinary network request metadata. The updater uses [Sparkle](https://sparkle-project.org/); its [license notices](./PasteLite/Resources/Sparkle-LICENSE.txt) are bundled with the app.

## Contributing

Bug reports, focused pull requests, and documentation improvements are welcome. Read the [contribution guide](./CONTRIBUTING.md) for setup, architecture, and validation steps. See the [changelog](./CHANGELOG.md) for project changes.

## License

Paste Lite is available under the [MIT License](./LICENSE).
