# 开发、验证与交付

[项目首页](../README.md) · [架构说明](architecture.md) · [历史验收](validation-history.md)

## 环境与构建

- macOS 14 或更高版本。
- 提供 Swift 6+ 的 Xcode 或 Command Line Tools；包的源码语言模式目前为 Swift 5。
- Node.js 用于本科课表解析器测试；缺少时脚本明确提示跳过，不应把这部分记为通过。
- Swift 测试包含 AppKit、WebKit、本机 HTTP 和文件事件，执行环境必须允许对应系统服务。

在仓库根目录执行：

```sh
swift --version
xcode-select --print-path
./scripts/build-macos.sh
./scripts/run-macos.sh
```

`build-macos.sh` 构建 Release 的 `Teachshelf` 和 `TeachshelfMCP`，在暂存包中加入资源后进行 ad hoc 签名与严格校验，再替换 `build/Teachshelf.app`。它不会替换 `/Applications/课屿.app`。`run-macos.sh` 只在构建产物不存在时触发构建，因此源码修改后需先运行构建脚本。

应用版本和构建号来自 [Resources/Info.plist](../Resources/Info.plist)；当前为 1.16.1（77）。应用版本、资料库 schemaVersion 和备份包格式分别管理，不能互相代替。仅修改文档时可保留应用版本，但仍需核对安装包与本次构建一致。

## 隔离运行

界面实验或导入测试使用新建的独立资料库：

```sh
open -n "$PWD/build/Teachshelf.app" --args --data-dir "$PWD/build/QA/manual-library"
```

`--data-dir` 仅覆盖该次启动的资料库，不改写应用记住的正式库路径；此模式默认不启动 MCP，避免占用正式端口。使用 `-n` 创建独立应用实例，并为每个同时运行的实例选择不同资料库。打开同一资料库的第二个写入者会被独占锁拒绝。

`build/`、`.build/` 为本机产物，`build/QA/` 可保存测试库、截图、备份和日志，不提交用户资料、密钥、Cookie 或 MCP 私有配置。故障注入只对测试创建的临时资料库与子进程执行，不能对正在使用的资料库执行。

## 自动验证

```sh
# 完整 macOS 回归；存在 Node.js 时包含 JS 解析器测试
./scripts/test-macos.sh

# 恢复、文件事务、迁移和 Finder 对账专项
./scripts/test-macos.sh --filter 'BackupRestoreRecoveryTests|LibraryRepositoryTests|PhysicalFolderTests|MaterialStorageTests|HomeworkStorageTests|FileSystemSyncTests|MaterialOrganizationTests'

# 工具接入及内置聊天
./scripts/test-macos.sh --filter 'PlanMCPServiceTests|LibraryMCPServiceTests|MCPTransportTests|AIChatTests|AIChatClientTests|AISettingsTests'

# 独立运行课表 JS 解析器测试
node scripts/test-nju-parser.js
```

| 测试 target | 覆盖重点 |
| --- | --- |
| `TeachshelfCoreTests` | 模型、计划与课表、资料组织、物理存储、备份恢复、迁移、Finder 对账 |
| `TeachshelfMCPTests` | 参数与版本检查、课程资料修改、协议鉴权、真实 HTTP / stdio 往返 |
| `TeachshelfLayoutTests` | 布局、原生交互、AI 配置与请求、文件事件、WebKit 夹具及教学更新流程 |

测试脚本处理 Command Line Tools 的 Testing framework、插件与链接路径；直接运行裸 `swift test` 不一定具有相同配置。WebKit 子进程被限制时，应报告环境失败，不应跳过后仍声称完整回归通过。

`BackupRestoreRecoveryTests` 用独立 runner 子进程和父进程 `SIGKILL` 验证真实终止，包括恢复自身再中断；还覆盖普通异常、损坏日志、越界路径和符号链接。启动时依赖 runner 的 bundle 参数，不要改成仅抛出异常来代替进程测试。详见 [故障验证边界](backup-restore.md#验证方法与边界)。

最近完整功能回归记录为 2026-10-26 的 `fff296d`：417 项 Swift 测试／52 个套件、15 项 JS 测试通过，恢复相关专项 103 项通过。文档修订应报告本次实际检查；引用历史结果时须保留日期和对应实现，不将历史通过记录当成本次运行结果。

## 修改与验证的对应关系

| 改动 | 相关验证 |
| --- | --- |
| 索引、文件目录、备份恢复 | 恢复与存储专项；关键提交点变动必须保留真实进程终止测试；再执行完整 macOS 回归 |
| AI / MCP 参数或执行流程 | 服务与传输回归、内置聊天确认／取消／版本冲突回归 |
| 原生布局与交互 | 对应布局测试；必要时用隔离资料库检查真实窗口 |
| 文档与示例 | 本地链接与锚点、JSON 示例、命令和源码名称、版本／工具数量一致性及差异检查 |

不要为了文档改动制造镜像实现的测试。真实网站、外部模型和界面操作只有本次实际执行后才能记为已验收；自动夹具不代表学校会话、真实下载或正式分发验收。

## 提交、安装与核对

协作流程以仓库 [AGENTS.md](../AGENTS.md) 及用户当次要求为准：

1. 检查分支、HEAD 和工作区，只提交本次改动，保留其他未提交内容。
2. 完成相关验证并创建本地提交。未配置 Git 身份时，使用约定的单次命令身份，不修改全局配置。
3. 构建 Release 并验证签名；正常退出已安装课屿，处理未保存内容，不强制结束进程。
4. 保留可恢复的旧应用副本，再替换 `/Applications/课屿.app`；替换失败恢复旧版，不改动用户资料库。
5. 打开安装版，核对版本、构建号、签名、程序哈希与实际运行路径，确认与本次构建一致。
6. 报告提交、实际验证和安装启动结果。远程推送、合并或发布须在用户授权范围内执行。

签名与版本检查示例：

```sh
codesign --verify --deep --strict "build/Teachshelf.app"
plutil -extract CFBundleShortVersionString raw -o - "build/Teachshelf.app/Contents/Info.plist"
plutil -extract CFBundleVersion raw -o - "build/Teachshelf.app/Contents/Info.plist"
```

版本号相同不等于安装包来自同一次构建。安装记录应保存提交 SHA、应用及 MCP 可执行文件哈希、验证日志、旧应用位置；不要只根据窗口外观判断正在运行哪一版。

## 后续待办

| 事项 | 后续范围与验收方向 |
| --- | --- |
| 大资料库性能 | 用人工生成的数据测量扫描、事务预检、启动、备份与恢复的耗时、内存和磁盘开销，记录可比较的规模与基线 |
| 学校网站内容更新检测 | 在现有来源映射上研究远端版本／内容变化，区分同址替换、缺失副本和本地修改；补充真实学校网站验收 |
| 正式分发 | Developer ID 签名、公证、分发包、权限／钥匙串升级表现及升级回退验证 |

这些项目仍是待办，不属于已实现或已验收能力。
