# Paste Lite Logo

蓝紫色满幅背景与叠放的剪贴卡片，表达复制、保存和再次使用。保留白色剪贴板、淡紫色后卡片和两条蓝色横线。

- 原生图标：[AppIcon.icon](../PasteLite/AppIcon.icon)，由 Xcode 26 及以上版本编译。
- 满幅源图：[Artwork.png](../PasteLite/AppIcon.icon/Assets/Artwork.png)，1024 × 1024、不透明；不预先绘制外圆角或透明留白。
- 系统渲染预览：[logo.png](logo.png)，由 Apple Icon Composer 的 `ictool` 导出。
- 生成方式：内置 image_gen 编辑原 Logo，系统 sips 统一源图尺寸，Icon Composer 负责外轮廓和系统显示效果。
- macOS 26 使用原生图标资源；Xcode 同时生成兼容旧版 macOS 的 ICNS。应用最低版本仍为 macOS 14。
- “关于”窗口通过 NSWorkspace 读取应用的系统图标，避免显示未裁切的源图。
- 菜单栏继续使用独立的 [MenuBarIcon.svg](../PasteLite/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.svg)，针对 18 pt 显示尺寸绘制单色轮廓。

## 满幅背景修正

旧版 PNG 已经包含圆角和透明留白，在 macOS 26 中出现灰色外框与缩小的内部图标。新版使用满幅不透明素材和原生 `.icon` 资源，让系统统一处理外轮廓。依据：[Apple App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons)、[Creating your app icon using Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。

## 最终编辑提示词

```text
Use case: precise-object-edit. Edit target: the attached Paste Lite application icon. Produce the final full-bleed artwork for a macOS 26 Icon Composer background, square 1024 x 1024. Keep the existing identity: blue-violet/indigo gradient, a centered white rounded clipboard with raised tab and circular blue hole, two thick blue horizontal lines, and one pale lavender sheet slightly offset behind it. Main change: completely REMOVE the outer rounded-square silhouette and ALL transparent margins, extending the blue-violet gradient continuously to all four edges and all four corners of the square canvas. The whole output must be opaque, no alpha transparency. No visible outer boundary or inset tile, no gray or white outer plate, no frame. This is a full-bleed square source image; macOS will mask the outer shape itself. Increase the white/lavender clipboard group modestly to about 62 percent of canvas width and 70 percent of canvas height, centered with balanced surrounding blue negative space. Preserve the soft clean material, subtle shadows under sheets, straight-on view, crisp smooth shapes. Only adjust framing and full-bleed background; retain the clipboard design. No text, no watermark, no mockup, no perspective.
```
