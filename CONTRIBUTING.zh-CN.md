# 为 Paste Lite 贡献

[English](./CONTRIBUTING.md) | 简体中文

感谢你帮助改进 Paste Lite。围绕单一问题的小改动更容易评审和维护。

## 反馈问题

提交前先查看已有 Issue。请提供 macOS 版本、“关于 Paste Lite”中的应用版本和构建号、复现步骤、预期行为与实际行为。构建问题还需要 Xcode 版本和相关错误输出。

请使用示例剪贴板内容，并移除截图、日志中的个人信息。权限问题请说明安装路径、签名方式，以及最近是否重新构建过应用；不要上传剪贴板数据库或凭证。

## 开发环境

需要配备 Xcode 26 或更新版本的 Mac。应用支持 macOS 14 及以上版本，没有第三方包依赖。

1. Fork 并克隆仓库。
2. 为本次修改创建分支。
3. 在 Xcode 中打开 `PasteLite.xcodeproj`。
4. 选择 `PasteLite` scheme 和 **My Mac**，构建并运行。

也可以在仓库根目录执行：

```bash
xcodebuild \
  -project PasteLite.xcodeproj \
  -scheme PasteLite \
  -configuration Debug \
  -derivedDataPath .build \
  build
```

构建 Release 时，将 `Debug` 替换为 `Release`。产物名为 `Paste Lite.app`，scheme、模块和可执行文件名为 `PasteLite`。

默认使用临时签名，便于本地开发；重新构建后辅助功能授权可能失效。请避免同时运行开发版本和已安装版本：它们共用 bundle identifier 和数据目录。下文的隔离回归测试不会使用正式历史库。

## 项目结构

| 路径 | 职责 |
| --- | --- |
| `PasteLite/App/` | 应用生命周期、菜单栏、快捷键和关于窗口 |
| `PasteLite/Models/` | 剪贴板采集结果与历史记录值类型 |
| `PasteLite/Services/` | 剪贴板监测、SwiftData 存储、全局快捷键和粘贴 |
| `PasteLite/UI/` | SwiftUI 视图、展示状态、面板控制器和图片加载 |
| `PasteLite/AppIcon.icon/` | 原生应用图标源文件 |
| `Tests/` | 独立回归测试 |
| `docs/` | Logo 预览和品牌说明 |

## 实现约定

AI 编码工具还应遵循 [AGENTS.md](./AGENTS.md) 中的项目约定。

- 优先使用直接的代码和已有模式，仅在解决实际问题时增加抽象或依赖。
- 图片解码和存储工作放在后台执行，界面更新保留在主 actor。
- 保持已有历史数据与文件引用行为兼容；修改 SwiftData 模型或存储格式时考虑迁移。
- `PasteLite` 模块名参与持久化模型身份，不要因为修改显示名称而一起重命名。
- 不提交凭证、个人路径、用户历史、本地 IDE 设置和构建产物。
- 新增 Swift 文件时，将其加入 Xcode target；测试构建需要该文件时，同步更新 `Tests/run.sh`。

## 验证

构建本次改动影响的配置。涉及剪贴板采集、筛选、存储或图片处理时，运行：

```bash
sh Tests/run.sh
```

测试使用临时数据库和独立命名的剪贴板，覆盖 PNG/TIFF/JPEG 采集、图片文件分类、搜索、缩略图、预览、文件粘贴语义、持久化重载和图片缺失处理。不会修改正式历史或系统剪贴板，也不会验证真实辅助功能授权和跨应用自动粘贴。

界面改动需在浅色和深色外观下检查受影响的行为。粘贴改动需使用可丢弃的示例内容，手动验证有权限时的自动粘贴和无权限时的仅复制行为。未执行的检查不要标记为通过。

## 文档与更新日志

保持以下英文和中文文档同步：

| 英文 | 简体中文 |
| --- | --- |
| [README.md](./README.md) | [README.zh-CN.md](./README.zh-CN.md) |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | [CONTRIBUTING.zh-CN.md](./CONTRIBUTING.zh-CN.md) |
| [CHANGELOG.md](./CHANGELOG.md) | [CHANGELOG.zh-CN.md](./CHANGELOG.zh-CN.md) |

面向用户的变化写入两份更新日志的**未发布**部分，仅在实际发布时添加对应版本和日期。说明已知限制，使用仓库相对链接，避免写入特定电脑上的路径。

## Pull Request

说明解决的问题、修改后的行为和已执行的检查。视觉改动请提供使用示例内容的截图，无关清理单独提交。贡献遵循项目的 [MIT 许可证](./LICENSE)。
