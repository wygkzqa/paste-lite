<div align="center">
  <img src="./docs/logo.png" alt="Paste Lite" width="112" height="112" />

  <h1>Paste Lite</h1>

  <p><strong>轻量的 macOS 原生剪贴板管理工具。</strong></p>

  <p><a href="./README.md">English</a> | 简体中文</p>

  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&amp;logo=apple&amp;logoColor=white" alt="macOS 14 及以上" />
    <img src="https://img.shields.io/badge/SwiftUI-native-F05138?style=flat-square&amp;logo=swift&amp;logoColor=white" alt="原生 SwiftUI" />
    <img src="https://img.shields.io/badge/storage-local-6366F1?style=flat-square" alt="本地存储" />
    <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MIT-22C55E?style=flat-square" alt="MIT 许可证" /></a>
  </p>

  <p><a href="#开始使用">开始使用</a> · <a href="./CONTRIBUTING.zh-CN.md">参与贡献</a> · <a href="./CHANGELOG.zh-CN.md">更新日志</a></p>
</div>

## 关于

Paste Lite 常驻 macOS 菜单栏，让复制过的内容随时可用。按下 **⇧⌘V**，找到需要的记录，即可在当前应用中再次使用。

应用使用 SwiftUI、AppKit 和 SwiftData 构建，历史记录保存在本机，无需账号，不提供云同步，也不收集遥测数据。应用界面目前为简体中文，项目文档提供英文和中文版本。

## 功能

- **剪贴板历史** — 保存纯文本、链接、图片和文件引用，相同内容自动去重。
- **快速搜索** — 搜索内容、文件名和来源应用，并按内容类型、应用筛选。
- **图片预览** — 在列表中显示缩略图，也可展开侧边栏查看图片、文本、链接或文件路径。
- **快捷键操作** — 使用 ⇧⌘V 打开历史，通过方向键选择，用 ⌘1–9 快速使用前九条结果。
- **返回原应用** — 双击记录或按 Return，将内容复制并尝试粘贴到原应用；自动粘贴需要辅助功能权限。
- **原生界面** — 常驻菜单栏、不占用 Dock，跟随系统明暗外观，按日期分组，在打开面板时统一计算时间标签。
- **本地存储** — 历史记录和采集的图片保存在磁盘中，电脑睡眠或用户会话不活跃时暂停监测。

单个图片文件也会出现在“图片”分类中，重新复制时仍保留文件形式。

## 开始使用

### 环境要求

- 运行应用需要 macOS 14 或更新版本。
- 构建需要 Xcode 26 或更新版本，用于编译原生 `.icon` 图标资源。

### 从源码构建

下载或克隆本仓库，在项目根目录执行：

```bash
xcodebuild \
  -project PasteLite.xcodeproj \
  -scheme PasteLite \
  -configuration Release \
  -derivedDataPath .build \
  build

open ".build/Build/Products/Release/Paste Lite.app"
```

如需安装，先退出正在运行的 Paste Lite，再通过 Finder 将 `.build/Build/Products/Release/Paste Lite.app` 复制到**应用程序**目录，启动安装后的应用。开发和测试方式见[贡献指南](./CONTRIBUTING.zh-CN.md)。

### 使用方式

| 操作 | 快捷键或交互 |
| --- | --- |
| 打开 / 关闭历史列表 | ⇧⌘V 或菜单栏菜单 |
| 选择记录 | 单击或 ↑ / ↓ |
| 复制并尝试粘贴记录 | 双击或 Return |
| 使用筛选结果中的前九条记录 | ⌘1–9 |
| 关闭面板 | Esc |
| 展开 / 收起预览 | 来源筛选旁的侧边栏按钮 |

选择记录不会触发粘贴，也不会让列表自动滚动。未获得辅助功能权限时，粘贴操作仍会把记录写入系统剪贴板；切回目标应用后，手动按 **⌘V** 即可。

## 辅助功能权限

点击历史面板中的**打开设置**，或前往**系统设置 → 隐私与安全性 → 辅助功能**，开启 Paste Lite 的权限。如果列表中没有应用，点击 **+** 添加 `/Applications/Paste Lite.app`。

**已知问题：**系统开关已经开启时，应用仍可能显示“未授权”，目前尚未解决。重启应用，或移除后重新添加安装版本可能有帮助，但不是已确认有效的修复。项目目前使用临时签名，替换构建也可能使旧授权失效。仍可使用复制后手动按 ⌘V 的方式。

## 数据与隐私

历史记录位于 `~/Library/Application Support/PasteLite/`。文件记录只保存原始路径引用，不会备份文件；原文件被移动或删除后，对应记录可能无法继续使用。

- 每两秒检查一次剪贴板，因此快速连续复制的内容不一定全部被记录。
- 历史最多保存 1,000 条，记录负载上限为 500 MiB。该限制不是总磁盘占用上限，数据库开销和缩略图另计。
- 纯文本上限为 2 MiB，单张保存为 PNG 的图片上限为 25 MiB。
- 忽略标记为机密、临时或自动生成的剪贴板内容，不会自动识别未标记的密码等敏感文本。
- 数据仅保存在本机，但应用不会对其加密，请像其他个人文件一样妥善保护。

## 参与贡献

欢迎提交问题、围绕单一需求的 Pull Request，以及文档改进。[贡献指南](./CONTRIBUTING.zh-CN.md)介绍了开发环境、项目结构和验证方式；项目变化见[更新日志](./CHANGELOG.zh-CN.md)。

## 许可证

Paste Lite 使用 [MIT 许可证](./LICENSE)。
