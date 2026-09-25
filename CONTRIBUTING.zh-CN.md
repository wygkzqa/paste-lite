# 为 Paste Lite 贡献

[English](./CONTRIBUTING.md) | 简体中文

感谢你帮助改进 Paste Lite。围绕单一问题的小改动更容易评审和维护。

## 反馈问题

提交前先查看已有 Issue。请提供 macOS 版本、“关于 Paste Lite”中的应用版本和构建号、复现步骤、预期行为与实际行为。构建问题还需要 Xcode 版本和相关错误输出。

请使用示例剪贴板内容，并移除截图、日志中的个人信息。权限问题请说明安装路径、签名方式，以及最近是否重新构建过应用；不要上传剪贴板数据库或凭证。

## 开发环境

需要配备 Xcode 26 或更新版本的 Mac。应用支持 macOS 14 及以上版本，Xcode 通过 Swift Package Manager 解析固定版本的 Sparkle 更新框架。

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

构建 Universal Release 时，将 `Debug` 替换为 `Release`，并添加 `-destination 'generic/platform=macOS'`。产物名为 `Paste Lite.app`，scheme、模块和可执行文件名为 `PasteLite`。

默认使用临时签名，便于本地开发；重新构建后辅助功能授权可能失效。请避免同时运行开发版本和已安装版本：它们共用 bundle identifier 和数据目录。下文的隔离回归测试不会使用正式历史库。

## 打包发布

日常 PR 的改动累积在 `main`，合并单个 PR 不会发布新版本；用户可见变化先写入两份 CHANGELOG 的「未发布」部分，等待发版要求。修复问题使用补丁版本（例如 `1.0.1`），兼容的新功能使用次版本（`1.1.0`），不兼容改动使用主版本（`2.0.0`）。

发版时单独创建发布 PR，统一更新应用版本、递增构建号，并同步双语更新日志和下载文档。合并后，为该 PR 的确切合并提交创建 `vX.Y.Z` 标签并从该提交构建，即使此后已有其他 PR 合入 `main`。不移动或复用已发布版本的标签。

运行 `sh scripts/package-release.sh`，构建 Universal Release 应用，检查双架构及签名，在 `.build/releases/<version>/` 中生成 DMG 和 `SHA256SUMS.txt`。脚本不会覆盖已有 DMG，也不会执行发布或公证。当前项目采用临时签名。

在选定的发布提交上运行 `sh Tests/run.sh`。在已安装 Rosetta 的 Apple Silicon Mac 上，再运行 `TEST_ARCH=x86_64 sh Tests/run.sh`；两套测试共用 `.build/tests/`，需顺序执行。Rosetta 测试通过不能替代 Intel 实机验证。使用最终 DMG 验证安装并如实记录限制，将 DMG 与校验文件作为 Release 附件上传。二进制文件和验证日志不提交到 Git。

[CI](./.github/workflows/ci.yml) 在每个 PR 和 `main` 推送时，使用标准 Apple Silicon 与 Intel macOS 云端机器运行隔离回归测试，固定 Xcode 26.6，并复用现有打包脚本构建 Universal DMG。在工作流运行详情的 **Artifacts** 中下载 `paste-lite-universal`；临时产物保留 7 天。云端测试不能替代实际安装、辅助功能授权和跨应用粘贴检查。

[Release](./.github/workflows/release.yml) 在推送 `v*` 标签时复用上述检查，要求标签格式为稳定版本 `vX.Y.Z`、与应用版本一致、提交已合入 `main`，且两份更新日志均包含该版本说明。随后创建带有 DMG、已签名的 `appcast.xml`、校验文件和双语说明的 Release **草稿**，并重新下载校验已上传附件。检查最终 DMG 和说明后，再正式发布并设为 Latest。不会覆盖已有 Release；若创建草稿后上传失败，先检查并仅删除该未完成草稿，再重新运行，保持原标签不变。

只需要构建时，打开 **Actions → Release → Run workflow**，选择 `main` 并运行。它会验证安装包和说明，上传相同的临时产物，但不会创建标签或 Release，也不会递增应用版本，可用于验证云端流水线。

发布任务单独使用具有 `contents: write` 的 `GITHUB_TOKEN`；PR 检查只有仓库读取权限，不接收发布凭证。当前临时签名构建不需要个人 Token 或 Apple 签名证书；发布在线更新需要另外配置下文的 Sparkle 签名密钥。版本标签创建应限制给维护者，已发布标签禁止修改和删除，`main` 要求通过 PR 及两项 CI 检查后合并。这些限制需在仓库 Settings 中配置，工作流文件本身不会设置仓库规则。任何受 Git 管理的文件如需修正，仍先通过另一个 PR 合并，再确定最终发布提交。

### 配置在线更新发布

Sparkle 2.10.0 通过 Swift Package Manager 与 `Package.resolved` 固定版本。Xcode 会解析框架及其 `bin/generate_keys`、`bin/sign_update`、`bin/generate_appcast` 工具，应用内包含上游许可证。启用更新时不要更改模块名、应用身份或数据目录。

首个带更新器的版本发布前：

1. 使用 Sparkle 的 `generate_keys --account paste-lite-updates` 生成专用 Ed25519 密钥并安全备份私钥。将输出的**公钥**填入仓库 Actions 变量 `SPARKLE_PUBLIC_ED_KEY`；普通构建可不配置，此时会明确禁用在线更新。
2. 创建受保护的 Actions environment，名称为 `release`，限制部署引用为版本标签（手动构建时可允许 `main`），并设置审核者。将导出的私钥种子保存为该环境的 `SPARKLE_PRIVATE_KEY` secret。遵循官方[密钥生成与备份说明](https://sparkle-project.org/documentation/#3-segue-for-security-concerns)，不提交私钥或通过命令行参数传入。临时导出文件仅放在已忽略的位置，限制文件权限，配置 Secret 后删除。
3. 仅首次建立清单时，将仓库变量 `SPARKLE_INITIALIZE_FROM` 设为没有 appcast 的上一已发布旧版本标签，目前为 `v1.0.0`；首份签名清单发布后删除该变量。其他情况下，清单缺失与网络错误都必须中止发布。
4. 沿用发布 PR 与标签流程，CI 将配置的公钥嵌入应用。macOS 发布任务校验最终 DMG，用包内公钥验证签名，保留上一份签名清单中的版本，拒绝未递增构建号，再签署新清单。只有标签签名步骤接收私钥；PR 与手动构建不签署或发布在线更新。
5. 核对草稿后发布并设为 Latest。以后每个 Latest 都必须包含 `appcast.xml`，固定地址为 `https://github.com/wygkzqa/paste-lite/releases/latest/download/appcast.xml`；清单内 DMG 地址使用明确的版本标签。不修改已发布签名附件，也不将缺少清单的旧版设为 Latest。

本地构建带公钥的包可运行 `SPARKLE_PUBLIC_ED_KEY='<公钥>' sh scripts/package-release.sh`。本地清单准备参数见 `scripts/prepare-update.py --help`，它要求环境变量 `SPARKLE_PRIVATE_KEY`，并显式指定上一清单或初始化选项；不要对已发布包执行。当前流程要求使用相同签名密钥延续清单，密钥轮换需另行设计迁移。Developer ID 签名与公证仍与 Sparkle 更新签名相互独立。

### 更新集成测试

解析依赖后，在具有图形会话的 Mac 上运行隔离升级测试：

```bash
xcodebuild -resolvePackageDependencies -project PasteLite.xcodeproj -scheme PasteLite \
  -clonedSourcePackagesDirPath .build/SourcePackages -onlyUsePackageVersionsFromResolvedFile
python3 Tests/run-updates.py \
  --sparkle-directory .build/SourcePackages/artifacts/sparkle/Sparkle
```

测试使用 `UPDATE_TESTING` 编译独立身份的原生应用，在 Keychain 之外生成临时密钥，通过本机地址提供签名清单，验证真实 DMG 替换重启、偏好保留、取消、准备好更新后退出、无新版本、安装包篡改和清单篡改，结束后清理测试应用、偏好和权限记录。正式 target 不得启用 `UPDATE_TESTING`；仅该测试构建允许本机 HTTP 清单，普通构建要求 HTTPS。主回归测试还验证退出时等待已排队写入、重新打开后数据完整。真实界面交互、辅助功能权限与最低系统版本仍需对应环境验证。

## 项目结构

| 路径 | 职责 |
| --- | --- |
| `PasteLite/App/` | 应用生命周期、菜单栏、快捷键和关于窗口 |
| `PasteLite/Models/` | 剪贴板采集结果与历史记录值类型 |
| `PasteLite/Services/` | 剪贴板监测、SwiftData 存储、全局快捷键和粘贴 |
| `PasteLite/UI/` | SwiftUI 视图、展示状态、面板控制器和图片加载 |
| `PasteLite/AppIcon.icon/` | 原生应用图标源文件 |
| `Tests/` | 独立回归测试 |
| `docs/` | README 图片资源 |

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

导入测试构造合成 SQLite/WAL 数据库与压缩附件，覆盖源数据不变、内容映射、原始元数据、去重、容量扩展持久化、预览过期、取消清理和附件部分写入后的回滚。不要使用个人 Paste 数据库作为测试样本。格式兼容通过已验证的实体哈希控制，变更需要新增合成用例并明确核对兼容范围。

界面改动需在浅色和深色外观下检查受影响的行为。粘贴改动需使用可丢弃的示例内容，手动验证有权限时的自动粘贴和无权限时的仅复制行为。未执行的检查不要标记为通过。

保持 `en.lproj` 和 `zh-Hans.lproj` 文案同步，并检查两种语言，尤其是较长的英文标签。`AppSettings` 将语言选择与历史分开保存，`L10n` 在显示时读取翻译。切换时保留内容、稳定的筛选值和列表时间快照。语言回归使用隔离数据与偏好，覆盖默认回退、偏好持久化、翻译占位符及展示状态保留。

## 文档与更新日志

保持以下英文和中文文档同步：

| 英文 | 简体中文 |
| --- | --- |
| [README.md](./README.md) | [README.zh-CN.md](./README.zh-CN.md) |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | [CONTRIBUTING.zh-CN.md](./CONTRIBUTING.zh-CN.md) |
| [CHANGELOG.md](./CHANGELOG.md) | [CHANGELOG.zh-CN.md](./CHANGELOG.zh-CN.md) |

面向用户的变化写入两份更新日志的**未发布**部分，仅在实际发布时添加对应版本和日期。说明已知限制，使用仓库相对链接，避免写入特定电脑上的路径。

功能方案、设计过程、验证记录和性能报告保存在已忽略的 `.build/` 目录下，`docs/` 仅保留公开文档需要的资源。

## Pull Request

所有仓库改动（包括代码、文档、配置和版本准备）通过独立分支创建 PR 并合并到 `main`，不直接向 `main` 提交或推送改动。Codex 创建的分支使用 `codex/` 前缀。合并前完成适用验证与评审，遵守仓库规则，不绕过检查或强推 `main`。优先使用 Squash merge，让一个 PR 对应一个主分支提交。

网页和命令行创建 PR 时，均使用 [PR 模板](./.github/pull_request_template.md)。保留**变更说明**、**主要改动**、**验证**三个部分，没有关联问题时删除**关联问题**部分。正文使用中文或英文即可，无需重复翻译，篇幅与改动规模相匹配。说明解决的问题、修改后的行为和主要改动，仅填写实际执行的检查及结果，并明确未验证的部分。视觉改动请提供使用示例内容的截图。

标题使用 `类型: 简短描述`，选择合适的常见前缀，如 `feat:`、`fix:`、`docs:`、`ci:` 或 `chore:`。发布准备 PR 使用 `chore: release vX.Y.Z`。模板合并到默认分支后，GitHub 网页创建 PR 时会自动填入。使用 `gh pr create --body-file` 时，应先按同一模板准备正文，不假设命令行会自动插入模板。模板用于引导格式，目前没有自动校验 PR 格式的检查。

无关清理单独提交。贡献遵循项目的 [MIT 许可证](./LICENSE)。

登录项测试使用替代服务，覆盖注册、关闭、待允许、失败及重复切换，不修改真实登录项。应用使用 `SMAppService.mainApp`；手动验证系统注册时使用独立且已签名的测试应用，结束后恢复原状态。

### 性能检查

使用 `sh Tests/Performance/run-model.sh` 运行隔离的 1,000 / 10,000 / 50,000 条记录基准；使用 `sh Tests/Performance/build-scroll.sh` 构建原生滚动压测窗口，使用真实列表组件与合成数据，不访问系统剪贴板。本地报告和测量结果保存在已忽略的 `.build/performance/` 目录下，不提交到代码库。耗时与显示链采样用于诊断，不作为固定通过阈值或帧率保证。
