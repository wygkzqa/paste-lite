# AGENTS.md

本文件供 AI 编码工具在 Paste Lite 仓库中工作时使用，适用于整个项目。其他工具需要项目规则时应引用此文件，避免维护内容不同的副本。开发环境与贡献流程见 [CONTRIBUTING.md](./CONTRIBUTING.md) / [中文贡献指南](./CONTRIBUTING.zh-CN.md)。

Paste Lite 是使用 SwiftUI、AppKit 和 SwiftData 构建的 macOS 原生剪贴板管理工具。

## 工作原则

- 以用户当前要求、正确性和数据兼容性为先，先阅读相关实现，再选择最直接的修改方式。
- 保持 macOS 原生应用定位；未经需求要求，不引入其他平台、Web UI、网络服务或第三方依赖。
- 保留工作区已有改动，不覆盖、回滚或顺手提交与当前任务无关的内容。
- 不为假设中的未来需求增加层级、包装类型或通用框架；适量重复可以比提前抽象更清楚。
- 修改完成后检查能否删除不必要的辅助函数、分支和中间变量。

## 技术栈

| 范围 | 当前实现 |
| --- | --- |
| 运行环境 | macOS 14 及以上 |
| 构建工具 | Xcode 26 及以上，`xcodebuild` |
| 语言 | Swift，项目使用 Swift 5 语言模式 |
| 界面 | SwiftUI、AppKit、`NSPanel`、菜单栏 `NSStatusItem` |
| 展示状态 | Combine、`ObservableObject`、`@Published` |
| 持久化 | SwiftData；图片与缩略图单独落盘 |
| 系统能力 | `NSPasteboard`、Carbon 全局快捷键、Accessibility、Core Graphics |
| 图片处理 | ImageIO 降采样、`NSCache` |
| 测试 | `Tests/run.sh` 编译并执行独立 Swift 回归测试 |

## 目录与职责

```text
PasteLite/
  App/                  应用生命周期、菜单栏、关于窗口
  Models/               采集结果、历史记录和内容类型
  Services/             剪贴板监测、存储、快捷键、复制与粘贴
  UI/                   SwiftUI 视图、展示状态、面板控制和图片加载
  AppIcon.icon/         原生应用图标素材
  Assets.xcassets/      菜单栏图标等资源
PasteLite.xcodeproj/    Target、构建配置和资源注册
Tests/                  使用隔离数据的回归测试
docs/                   Logo 预览和品牌说明
```

### 系统与存储

- `ClipboardMonitor` 负责监测剪贴板变化、识别内容、跳过特定标记类型，以及睡眠和会话切换时的暂停与恢复。
- `ClipboardRepository` 对外提供历史数据；其内部 `ClipboardStorage` 负责 SwiftData、去重、容量清理、图片资源和旧数据迁移。
- `PasteService` 负责写回剪贴板、检查辅助功能权限、打开授权设置和发送粘贴快捷键。写回成功后保留监听回环抑制，避免把自身复制重复采集为新记录。
- `GlobalHotKeyManager` 管理全局快捷键的注册与释放。

### 界面与交互

- `ClipboardViewModel` 管理搜索、筛选、选中项与展示时间标签，不在 SwiftUI 视图中另建历史数据副本。
- `ClipboardPanelController` 管理窗口显隐、焦点、原应用恢复和键盘交互。
- 视图负责展示与交互回调；存储、权限请求和系统粘贴行为放在现有服务或控制器中。
- `ClipboardImageLoader` 负责后台降采样与缓存；列表和预览沿用这一加载路径。

## 构建与测试命令

以下命令在仓库根目录执行：

```bash
# 开发构建
xcodebuild -project PasteLite.xcodeproj -scheme PasteLite \
  -configuration Debug -derivedDataPath .build build

# Release 构建
xcodebuild -project PasteLite.xcodeproj -scheme PasteLite \
  -configuration Release -derivedDataPath .build build

# 图片与剪贴板回归测试
sh Tests/run.sh

# 检查修改中的空白问题
git diff --check
```

Release 产物为 `.build/Build/Products/Release/Paste Lite.app`。构建验证与安装是不同操作；仅在任务包含安装或更新应用时替换安装版本，复制前退出正在运行的应用。

当前没有配置独立的格式化工具或 CI 工作流，不要把不存在的 lint、测试或流水线命令写进交付结果。

## Swift 与并发约定

- 使用四个空格缩进，类型使用 `UpperCamelCase`，属性和方法使用 `lowerCamelCase`，优先选择具体、常见的业务名称。
- 沿用现有风格和框架，不因局部改动引入新的状态管理或服务架构。
- 尽量让主流程从上到下可读，适当使用 `guard` 提前返回；注释解释隐藏约束或原因，避免逐行复述代码。
- UI 和可观察状态更新在主 actor 上执行。存储、图片转换和较重的解码工作放到后台，避免在视图 `body` 或点击回调中执行同步磁盘操作。
- SwiftData 的 `ModelContext` 在所属执行上下文内创建与使用，不跨队列传递上下文或其模型对象。
- 异步图片结果应用到视图前检查取消状态；切换记录时清理旧预览，避免显示上一项的图片。
- 注册的通知、事件监听、计时器和快捷键应有对应的释放或停止逻辑。
- 新增 Swift 文件时同步加入 Xcode target；如果独立测试编译需要该文件，也更新 `Tests/run.sh`。

## 数据兼容与隐私

- 显示名称为 **Paste Lite**，scheme、模块和可执行文件名为 `PasteLite`。不要为显示名称调整而更改模块名，SwiftData 持久化模型身份依赖它。
- 当前 bundle identifier 为 `com.local.PasteLite`，数据目录为 `~/Library/Application Support/PasteLite/`。修改标识、目录或模型结构时，先考虑已有数据和授权的迁移。
- 保留历史去重、容量限制、资源清理及旧 JSON 数据迁移行为，不通过删除用户历史来掩盖迁移或加载错误。
- 文件记录保存路径引用，不是文件备份。单个图片文件通过 `hasImage` 参与图片筛选和预览，但粘贴时仍使用文件 URL。
- 权限缺失时保留复制到系统剪贴板的行为，供用户手动按 ⌘V 粘贴。
- 本地数据未经应用加密；跳过机密等剪贴板标记不等于能够识别所有密码或密钥，文档与界面不要作超出实现的隐私承诺。
- 测试使用临时目录、独立数据库和命名剪贴板；不要读取真实历史内容、记录真实剪贴板文本，或在截图中使用个人数据。
- 提交前检查文件范围，排除 `.build/`、IDE 用户设置、凭证、签名材料及个人绝对路径。

## 需要保持的交互

除非任务明确要求调整，否则保持以下行为：

- ⇧⌘V 打开或关闭列表；单击仅选择，双击或 Return 执行复制并尝试粘贴，⌘1–9 使用筛选结果中的前九项。
- 列表不会因选中、搜索或键盘切换而自动滚动；不要重新加入自动 `scrollTo`。
- 相对时间标签在打开列表时统一计算，不添加持续计时的刷新逻辑。
- 应用常驻菜单栏，不显示 Dock 图标；使用系统语义颜色与材质，并兼顾浅色和深色外观。
- 主图标沿用 `.icon` 资源与满幅素材，菜单栏使用独立模板图标；品牌素材约定见 [docs/branding.md](./docs/branding.md)。

## 权限与签名

项目目前使用临时签名。新构建可能导致旧辅助功能授权失效，系统开关开启但应用仍判断未授权的问题也尚未解决，见两份 README 的已知问题说明。

排查时区分系统设置、当前运行的应用路径与进程返回的权限状态。不要通过隐藏提示或硬编码为已授权来处理问题，也不要把单独测试进程的权限结果当作应用的权限。构建通过不代表真实授权或跨应用粘贴已经验证。

## 文档与提交

- README、CONTRIBUTING、CHANGELOG 分别维护英文 `.md` 与简体中文 `.zh-CN.md`，同一变更同步更新相关语言版本。
- 面向用户的变更写入两份 CHANGELOG 的未发布部分；仅在实际发布时记录发布版本和日期。
- 应用当前只有简体中文界面，英文文档不代表应用已经提供英文界面。
- 文档使用仓库相对链接和通用命令，描述已有能力，不虚构平台支持、发布包或验证结果。
- 提交信息简明描述改动，可使用 `docs:`、`fix:`、`feat:` 等前缀。仅提交本任务内容，遵循用户指定的分支和推送范围，不擅自强推或改写已有历史。

## 完成前验证

| 修改范围 | 验证方式 |
| --- | --- |
| 仅文档 | 检查相对链接、双语一致性、命令与代码是否对应；无需重新构建应用 |
| Swift 代码或 Xcode 配置 | 构建受影响配置，新增资源时检查是否随应用打包 |
| 图片、采集、筛选或存储 | 运行 `sh Tests/run.sh`，必要时增加覆盖真实边界的测试 |
| UI 与交互 | 实际检查受影响操作与浅色、深色外观，不只依赖编译 |
| 权限与自动粘贴 | 在真实应用中验证权限读取、原应用焦点恢复，以及无权限时的复制行为 |

回归测试不覆盖真实辅助功能授权或跨应用自动粘贴。交付时说明改动、实际执行的检查和仍未验证的部分；工具或环境阻塞时明确说明，不将尝试执行写成验证通过。
