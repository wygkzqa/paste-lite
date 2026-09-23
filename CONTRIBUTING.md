# Contributing to Paste Lite

English | [简体中文](./CONTRIBUTING.zh-CN.md)

Thank you for helping improve Paste Lite. Small, focused changes are easier to review and maintain.

## Report an issue

Check existing issues before opening a new one. Include the macOS version, app version and build number from **About Paste Lite**, reproduction steps, expected behavior, and actual behavior. For build problems, include your Xcode version and the relevant error output.

Use sample clipboard content and remove personal information from screenshots and logs. For permission issues, describe the installation path, signing method, and whether the app was recently rebuilt; do not attach clipboard databases or credentials.

## Development setup

Use a Mac with Xcode 26 or later. The application targets macOS 14 and later and has no third-party package dependencies.

1. Fork and clone the repository.
2. Create a branch for your change.
3. Open `PasteLite.xcodeproj` in Xcode.
4. Choose the `PasteLite` scheme and **My Mac**, then build and run.

From the repository root, you can also build with:

```bash
xcodebuild \
  -project PasteLite.xcodeproj \
  -scheme PasteLite \
  -configuration Debug \
  -derivedDataPath .build \
  build
```

For a Release build, replace `Debug` with `Release`. The product is named `Paste Lite.app`; the scheme, module, and executable are named `PasteLite`.

The default signing identity is ad-hoc for local development. Accessibility grants may become invalid after a rebuild. Avoid running the development and installed copies together: both use the same bundle identifier and data directory. The isolated regression tests described below avoid the normal history store.

## Project structure

| Path | Responsibility |
| --- | --- |
| `PasteLite/App/` | App lifecycle, menu bar, shortcuts, and About window |
| `PasteLite/Models/` | Clipboard capture and history value types |
| `PasteLite/Services/` | Pasteboard monitoring, SwiftData persistence, hotkeys, and pasting |
| `PasteLite/UI/` | SwiftUI views, presentation state, panel controller, and image loading |
| `PasteLite/AppIcon.icon/` | Native application icon source |
| `Tests/` | Standalone regression tests |
| `docs/` | Logo preview and branding notes |

## Implementation guidelines

- Prefer direct code and the existing patterns. Add abstractions or dependencies only when they solve a concrete problem.
- Keep image decoding and storage work off the main thread; keep UI updates on the main actor.
- Preserve existing history data and file-reference behavior. Consider migration when changing SwiftData models or storage formats.
- The `PasteLite` module name participates in persisted model identity. Do not rename it as part of a display-name change.
- Keep credentials, personal paths, user history, local IDE settings, and build products out of commits.
- If you add a Swift file, include it in the Xcode target and update `Tests/run.sh` when its test build requires it.

## Validation

Build the configuration affected by your change. For changes to clipboard capture, filtering, storage, or image handling, run:

```bash
sh Tests/run.sh
```

The tests use a temporary database and named pasteboards. They cover PNG/TIFF/JPEG capture, image-file filtering, search, thumbnails, previews, file paste semantics, persistence reloads, and missing-image handling. They do not modify normal history or the system clipboard, and do not validate live Accessibility authorization or automatic pasting into other apps.

For UI changes, check the affected behavior in light and dark appearance. For paste changes, manually check both authorized automatic pasting and the copy-only fallback using disposable sample content. Do not claim a check passed if it was not run.

## Documentation and changelog

Keep each English/Chinese pair in sync:

| English | Simplified Chinese |
| --- | --- |
| [README.md](./README.md) | [README.zh-CN.md](./README.zh-CN.md) |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | [CONTRIBUTING.zh-CN.md](./CONTRIBUTING.zh-CN.md) |
| [CHANGELOG.md](./CHANGELOG.md) | [CHANGELOG.zh-CN.md](./CHANGELOG.zh-CN.md) |

Put user-visible changes under **Unreleased** in both changelogs. Only add a release version and date when that release is actually published. Explain known limitations and use repository-relative links rather than machine-specific paths.

## Pull requests

Explain the problem, resulting behavior, and checks performed. Include screenshots for visual changes using synthetic content. Keep unrelated cleanup separate. Contributions are made under the project's [MIT License](./LICENSE).
