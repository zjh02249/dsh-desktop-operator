# 版本历史

本项目遵循 [Semantic Versioning](https://semver.org/)。在 `1.0.0` 之前，DSH 预发布 API 或 Computer Use 工具协议的变化仍可能带来不兼容调整。

## [0.12.0] - 2026-08-27

### 供应链与发布

- 新增 Windows Authenticode 签名入口，支持 GitHub Secrets 注入 PFX 或使用证书指纹；签名后同时执行 SignTool `/pa` 验证和 `Get-AuthenticodeSignature` 验证，并刷新 runtime manifest 哈希。
- 未配置维护者证书时不伪造成功：继续生成可测试的未签名包，同时发布机器可读 `windows-signing-report.json`；设置 `WINDOWS_SIGNING_REQUIRED=true` 可让发布失败关闭。
- 新增 CycloneDX 1.6 SBOM，覆盖完整 npm 生产依赖图和 x64/arm64 runtime 文件哈希；Release 工作流使用 GitHub 官方 action 生成 build provenance 与 SBOM attestation。
- 新增隔离 DSH Profile 验收，在独立 `DSH_HOME` 中执行上一稳定版 → 当前版 → 上一稳定版，并核对插件版本、原生 runtime 版本和唯一依赖绑定。
- Release 资产扩展为插件包、双架构 runtime、manifest、SBOM、签名状态、升级/回滚报告和统一 SHA-256 校验文件。

### 验证与边界

- 本地主机没有代码签名证书和 SignTool，因此 `0.12.0` 本地产物的真实状态是 `unsigned`；签名管线已实现，但不能把本次本地构建描述为已签名。
- 本地 CycloneDX SBOM 包含 99 个组件且依赖引用全部闭合；`0.11.0 → 0.12.0 → 0.11.0` 的隔离升级/回滚通过。
- 所有供应链脚本均按文件、依赖和版本工作，不含任何桌面应用专用逻辑。

## [0.11.0] - 2026-08-27

### 新增

- 新增只读 `find_elements` 工具，在当前 `WindowRef` 与 `observation_id` 内按名称、AutomationId、值、控件类型、类名和可用动作筛选语义元素；默认最多返回 20 项，硬上限 100 项。
- 新增负坐标、混合缩放和越界拒绝的确定性坐标自检，并在存在负坐标物理显示器时自动运行真实动作 smoke。
- 新增 Qt、Electron 和 Office 兼容应用质量矩阵、Windows 11 交互式自托管验收工作流与主机证据检查。
- 新增参数驱动的通用消息类应用验收器，应用、窗口、搜索框、消息编辑器和发送控件均由调用方显式提供；联系人必须显式传入，仓库不内置个人姓名。

### 安全与可靠性

- UIA 直接聚焦失败后的物理点击回退，必须先证明点击点命中目标元素或其子节点；同进程内任意焦点不再被视为成功，写入后仍需精确值回读。
- 仅当动作后的原窗口句柄已经确认失效时，才把快照竞争条件恢复为 `window_closed`；普通 stale/window-not-found 错误继续失败关闭。
- 生产系统提示与验收脚本均保持应用无关；具体桌面程序只允许作为外部质量矩阵数据或兼容性证据，不会向模型注入应用专用操作流程。

### 本次实机证据与边界

- Windows 10 22H2 x64 上，WPF/WinForms 可靠性 smoke、Qt 钉钉只读语义矩阵和 Electron DeepSeek Harness/ZCode 矩阵通过。
- 当前两台显示器均为非负坐标布局，负坐标通过确定性映射自检，尚未完成负坐标物理显示器动作验收。
- 当前主机未安装 Office/WPS，Windows 11 自托管工作流已建立但尚未在合格主机执行；这些缺口不会被描述为已实机通过。

## [0.10.0] - 2026-08-27

### 新增

- 使用每用户 JSONL 动作日志持久化 `idempotency_key`／`action_id` 哈希、动作状态、目标窗口身份和脱敏错误码，runtime 重启后仍能拒绝同一逻辑动作的重复派发。
- 动作审计覆盖 `reserved`、`dispatched`、`applied`、`rejected` 和 `unknown`；不记录输入文字、设置值、动作摘要或原始幂等键。
- runtime 启动时检查未完成动作的原进程；确认进程已经退出后，将悬挂动作保守恢复为 `unknown`，禁止自动重放可能已经生效的副作用。
- 新增 `doctor` 日志状态、`action-audit [limit]` 脱敏审计和 `action-journal-prune` 压缩维护命令。
- DSH 配置新增日志路径、保留天数和最大事件数；默认写入 `%LOCALAPPDATA%\dsh-desktop-operator\action-journal-v1.jsonl`。

### 可靠性

- 使用 Windows 命名互斥锁、同步落盘和原子替换，协调多个 runtime 的日志预留、恢复和压缩。
- 尾部中断写入可自动丢弃并恢复；日志中部损坏会失败关闭，避免绕过持久化幂等保护。
- 新增并发预留、跨重启重复拒绝、进程崩溃恢复、截断恢复、审计脱敏、保留策略和 CLI 回归测试。

## [0.9.0] - 2026-08-27

### 新增

- 为有副作用动作增加 `action_id`、`idempotency_key`、动作耗时诊断与重复派发拒绝。
- MCP server 支持标准 `notifications/cancelled`，可以取消排队调用并终止活动 PowerShell 动作。
- Windows runtime 使用命名互斥锁，在多个 DSH runtime 进程之间串行化前台激活和真实输入。
- 新增统一可靠性 smoke 入口，采集显示器、负坐标与 DPI 拓扑，并运行遮挡捕获、模态恢复和动作闭环。

### 安全与行为

- DSH adapter 默认使用 tool call id 填充动作 ID 和幂等键，同时保留调用方显式提供的逻辑操作键。
- 相同幂等键一旦进入原生动作派发就会失败关闭，要求重新观察后再决定下一步。
- runtime 结束、MCP 取消或调用超时时，活动桌面动作返回未验证语义，不会被当成安全成功。

## [0.8.0] - 2026-08-27

### 新增

- 所有有副作用的 Computer Use 工具都必须声明 `action_intent`。
- 对发送、提交、发布、删除、购买、审批、上传、权限变更、敏感数据暴露和安装动作提供 DSH 原生确认界面。
- `expected_postcondition` 新增 `window_closed`，并支持最多 8 项非嵌套 `all`/`any` 组合。
- 对语义明显的发送、删除、支付控件增加 action intent 反降级检查。

### 变更

- 产品正式命名为 `DSH Desktop Operator`，仓库和独立 package ID 统一为 `dsh-desktop-operator`。
- 新增完整中英文 README、显式语言切换、快速安装、平台矩阵和 GitHub 可发现性说明。
- `@valkia/dsh-plugin-computer-use` 仅保留为上游来源和旧安装迁移标识。

### 安全与行为

- 缺失或非法 action intent 时失败关闭。
- 高风险动作在 `highRiskActionPolicy: confirm` 下必须经过一次性用户确认。
- 窗口关闭和多信号结果可被明确验证，不再依赖陈旧快照推断成功。

## [0.7.0] - 2026-08-26

### 新增

- 识别阻断 owner window 的模态窗口，并返回精确 WindowRef 候选。
- 引入动作后置条件协议，区分 `applied` 与 `unknown`。
- 支持 `target_focused`、`target_value_equals`、`text_contains`、`foreground_window` 和 `screenshot_changed`。
- 增加 WinForms modal smoke 验证脚本。

### 修复

- 阻止向已被 owned modal 禁用的窗口发送前台输入。
- 无法验证动作结果时不再假报成功，也不会授权盲目重试有副作用的动作。

## [0.6.0] - 2026-08-26

### 新增

- 使用 Windows Graphics Capture 捕获被遮挡窗口。
- 物理坐标、DPI、虚拟桌面边界和过期截图保护。
- UIA 焦点身份、`set_value` 读回验证和前台输入保护。
- 顶部控制提示条、鼠标光环和平滑鼠标移动。
- Agent turn 级运行时租约与 turn-ended 清理。
- x64/arm64 runtime 构建和包内验证。

### 修复

- Agent turn、Agent 或 Session 结束后自动释放 Computer Use 占用。
- 窗口在截图后移动或缩放时拒绝旧坐标。
- 最小化窗口要求恢复并重新观察。

## [0.2.0] - 2026-08-26

### 新增

- 首个可安装的单仓库、自包含 DeepSeek Harness Computer Use 插件。
- 正式合并 Open Computer Use Windows runtime 源码、许可证和第三方声明。
- 提供 DSH MCP 桥接、Agent Preset 配置和 14 个桌面工具。
- 提供一键测试、x64/arm64 构建、打包和归档完整性校验。
- 建立长期 Codex Computer Use 能力对齐路线。

[0.12.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.12.0
[0.11.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.11.0
[0.10.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.10.0
[0.9.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.9.0
[0.8.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.8.0
[0.7.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.7.0
[0.6.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.6.0
[0.2.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.2.0
