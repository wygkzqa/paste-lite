# Changelog

English | [简体中文](./CHANGELOG.zh-CN.md)

Paste Lite has not been officially released. This section lists the features currently supported.

## Unreleased

### Fixed

- Keep the latest mouse selection when an earlier keyboard navigation finishes loading another page.
- Cancel pending paste reads when the history panel closes or opens again, so an old request cannot paste into a new target app.

### Features

- **Native macOS app** — supports macOS 14 and later, lives in the menu bar without a Dock icon, and follows the system light or dark appearance.
- **Open from Spotlight or Finder** — launching or reopening the app shows the main panel; reopening an already visible panel preserves search and any active editor. Login-item launches remain in the background.
- **Panel dismissal** — clicking outside the app closes the history panel even after opening filters or permission guidance; attached editing and preview sheets keep their existing behavior.
- **Compact layouts** — switch between List and Cards from the panel footer or Settings, with a shared saved preference; both use native Liquid Glass on macOS 26, translucent materials on earlier versions, and respect Reduce Transparency. Native window content is clipped to the panel’s rounded corners, with its shadow refreshed when opening or resizing.
- **Optional gradient background** — enable **Gradient Background** in General settings to add a blue-purple gradient to either layout; off by default, saved automatically, and adapted to light/dark mode and Reduce Transparency.
- **Selection highlight** — selected entries use a blue background with white text when the gradient is off; gradient mode keeps the translucent highlight in both layouts.
- **Groups** — create, rename, and delete groups; assign entries through a direct context submenu or footer menu, with checked/mixed membership states and batch add/remove; combine group filtering with database search and pagination. Deleting groups keeps history, and grouped entries follow existing retention rules.
- **Custom titles** — edit titles for text, link, image, and file entries from the context menu; restore automatic titles by clearing the field. Titles persist, appear in both layouts and previews, and are included in database search. Renaming keeps original content and ordering. Paste imports preserve titles and fill missing titles without overwriting local names.
- **Multiple selection and deletion** — ⌘-click toggles entries, ⇧-click/⇧arrows selects ranges, and ⌘A selects all filtered results across pages while retaining native text selection inside fields. Right-click preserves an existing multi-selection; confirmed single/batch deletion keeps group definitions and external files and removes only unreferenced image assets.
- **Entry editing** — right-click selects a list entry or card before opening its menu. Edit and Preview share a title-and-content form; text/link bodies can be edited, while images and files retain their original payload. Edits persist search summaries and deduplication hashes without changing timestamps or groups; invalid or duplicate content keeps the draft open with an error. Preview is available from the context menu.
- **Clipboard history** — saves plain text, links, images, and file references locally, with content deduplication and persistence across launches.
- **Search and filters** — queries all history in the database by content, filenames, and source apps, with type/application filters, paginated summaries, and on-demand full content.
- **Thumbnails and previews** — displays image thumbnails and an on-demand preview for images, text, links, or file paths. Single image files also appear in image filters and previews while retaining file paste behavior.
- **Time labels** — displays segmented time labels based on when the panel opens, without continuous updates.
- **Keyboard navigation** — opens or closes history with ⇧⌘V, selects with ↑ / ↓ while keeping the selected row visible, uses the first nine filtered results with ⌘1–9, and closes the panel with Esc.
- **Copy and paste** — a click selects a row without scrolling; double-click or Return copies it and attempts to paste into the previous app. Automatic pasting requires Accessibility permission; copying remains available for manual ⌘V.
- **Permission guidance** — opens macOS Accessibility settings from the history panel and rechecks authorization when the app becomes active or history opens.
- **Import from Paste** — imports supported local history from Settings → Data, preserving original timestamps, source apps, Pinboard names, and memberships. Includes empty boards, same-name group merging, multi-group deduplication, and adding missing memberships to existing records. Supports the data structure verified against Paste 6.0.3, scan previews, duplicate detection, skipped-item summaries, cancellation before the final save, and failure rollback without changing the source data.
- **Import entry options** — imports all supported entries by default; with an entry limit, imports recent entries that fit or raises that limit, without deleting existing history to make room.
- **Settings sidebar** — General, History, Data, and About categories with details on the right; language, layout, launch at login, and capture size limits are grouped under General.
- **Clear history** — confirms removal of all history, including grouped records, images, thumbnails, and legacy migration backups; preserves groups, settings, the current system clipboard, and original files, with cleanup errors and retry support.
- **Language settings** — follows the system by default or uses Simplified Chinese or English; changes apply immediately and persist across launches. Settings are available from the menu bar or with ⌘, while the app is active.
- **Launch at login** — an optional setting managed by macOS Login Items, with system status refresh and a link to the system settings when approval is needed.
- **About page** — displays the app logo, version, build number, and GitHub link in Settings; the menu bar’s About Paste Lite opens the same page.
- **Local data management** — stores history and captured images on disk, defaults to unlimited entries, permanent retention, and no total storage quota; settings control text/image capture limits, retention days, entry count, and cleanup intervals; and processes images and storage in the background. Monitoring pauses during sleep and inactive user sessions and skips clipboard entries marked concealed, transient, or automatically generated.
