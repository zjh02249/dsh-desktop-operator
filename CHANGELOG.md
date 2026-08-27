# 版本历史

本项目遵循 [Semantic Versioning](https://semver.org/)。在 `1.0.0` 之前，DSH 预发布 API 或 Computer Use 工具协议的变化仍可能带来不兼容调整。

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

[0.8.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.8.0
[0.7.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.7.0
[0.6.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.6.0
[0.2.0]: https://github.com/zjh02249/dsh-desktop-operator/releases/tag/v0.2.0
