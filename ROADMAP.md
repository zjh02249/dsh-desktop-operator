# DSH Computer Use：Codex 级 Windows 桌面控制长期路线

日期：2026-08-26
状态：实施中；M1 窗口身份、M3 首版前台 `SendInput`、M5a 代次拒绝／模态恢复／后置条件、M6a DSH 前台模式、M8a 单包集成已落地
范围：Windows 优先；DeepSeek Harness 集成；功能等效复刻，不复制未公开的 OpenAI 私有代码

## 1. 需求摘要与目标边界

### 目标

构建一套可由 DeepSeek Harness 稳定调用的 Windows Computer Use 系统，达到以下闭环：

1. 准确发现并绑定唯一目标窗口。
2. 在遮挡、多窗口、多显示器和 DPI 缩放下可靠观察。
3. 通过 UI Automation 或真实系统输入操作任意普通桌面程序。
4. 每个动作都验证目标窗口、焦点和界面后置条件。
5. 出现超时、窗口重建、模态框或未知结果时能够安全恢复。
6. 对发送、删除、上传、支付、权限变更等外部副作用执行动作前确认。
7. 在 Win32、WPF、WinUI/UWP、Qt、Electron/Chromium、Office 类程序上形成可重复的质量基线。

### 不承诺的范围

- 不绕过 UAC 安全桌面、锁屏、登录、验证码、密码管理器或安全软件。
- 不保证操作受 DRM、反作弊、管理员完整性级别隔离或自绘保护的界面。
- 不复刻 OpenAI 未公开的私有算法、二进制或内部协议；只对齐本机 Codex 暴露的可观察行为。
- 浏览器网页自动化不是首选路径；存在专用 Browser Use 时优先使用专用工具。

OpenAI 的 [Computer use 官方指南](https://developers.openai.com/api/docs/guides/tools-computer-use)确认模型可以通过内置工具或自定义 harness 执行截图—动作—截图循环，并要求对高影响动作保留人工确认、把屏幕内容视为不可信输入；Codex 桌面端实现细节没有完整公开，因此本路线的更细能力基线来自本机随 Codex 分发的 API 契约和运行指导。

## 2. 当前基线与主要差距

### 实施前开源运行时基线

- Windows MCP 最初只有 9 个应用级工具，且默认不自动启动应用、不 `SetFocus`、不启用 UIA 文本回退；该基线现已保留在 `runtime/windows/` 的 Git 演进记录中。
- Windows 的 `global` 与 `sky_click` 点击仍被明确拒绝，避免把其他平台的输入语义错误套用到 Windows。
- legacy 应用名入口仍保留 `PostMessage` / `SendMessage` 兼容；窗口级 v2 已改为前台验证后的 `SendInput`。
- UIA `SetFocus`、文本回退和应用启动仍由插件配置映射成显式环境开关。
- `actionResult` 已有窗口、焦点与快照代次校验，并实现首版业务后置条件 DSL；更复杂的组合条件与窗口关闭条件仍待后续扩展。

### 实施前 DSH 插件基线

- 插件实施前锁定外部 `open-computer-use@0.3.1`，运行时修复无法随插件源码一起维护。
- 插件实施前只负责定位 launcher、MCP 桥接、会话所有权、审批与清理。
- runtime 环境变量虽然可配置，但缺少面向 Windows 前台模式的显式配置。
- 模型提示只有通用“观察—动作—刷新”要求，没有强制窗口绑定、焦点后置条件和未知结果语义。

### Codex 可观察能力基线

- 使用具体 `Window { app, id, title }`，而不是松散应用名称：本机 bundled `computer-use/docs/api.md:30-34`。
- 提供 `list_windows`、`launch_app`、`get_window`、`activate_window`，输入动作自动激活目标窗口：同文件 `:14-26`。
- 坐标动作绑定最新 `screenshotId`，元素动作绑定最新 `element_index`：同文件 `:57-113`。
- 每次只执行一个动作并立即刷新，状态改变后不复用坐标、截图 ID 或元素索引：本机 bundled `computer-use/docs/guidance.md:79-81`、`:253-260`。
- 能识别非目标窗口覆盖、模态窗口和焦点状态，并执行有限恢复：同文件 `:213-220`。

## 3. 架构决策

### 选定方案：单仓分层、一个交付物

```text
DeepSeek Harness Agent
        │
        ▼
dsh-plugin-computer-use（策略与适配层）
  - session ownership / approval / confirmation
  - tool capability negotiation
  - prompt + attachment + lifecycle
        │ MCP stdio
        ▼
dsh-plugin-computer-use/runtime/windows（原生桌面 runtime）
  - Window Registry
  - Capture Engine
  - UIA Snapshot Engine
  - Foreground/Input Engine
  - Action Coordinator
  - Postcondition Verifier
        │
        ▼
Windows UIA + Win32 + Windows.Graphics.Capture + SendInput
```

策略层与原生运行时保持目录和进程边界，但源码、测试、许可证、二进制和发布流程全部归入同一个插件仓库。`open-computer-use-dsh` 只作为临时上游比较／同步区，不参与安装或运行；对用户始终只有一个插件包。

### 核心状态模型

```text
WindowRef
  appId, pid, hwnd, title, generation

Observation
  observationId, windowRef, captureIds[], accessibilityGeneration,
  focusedElement, modalWindows[], timestamp

ActionRequest
  windowRef, observationId, target, inputMode,
  expectedPostcondition, idempotencyKey

ActionResult
  status = applied | rejected | unknown
  before, after, diagnostics, retryable
```

所有状态衍生动作必须携带 `observationId`；窗口重建、树变化或新截图会使旧状态失效。

## 4. 长期 API 契约

在保持现有 9 个工具兼容的前提下，增加窗口级 v2 API：

- `list_apps`
- `list_windows`
- `launch_app`
- `get_window`
- `get_window_state`
- `activate_window`
- `click`
- `press_key`
- `type_text`
- `set_value`
- `scroll`
- `drag`
- `perform_secondary_action`

兼容策略：

- `get_app_state(app)` 保留为 v1 适配器，只在候选窗口唯一时转成 `get_window_state(window)`。
- 多个候选窗口时必须返回候选列表，禁止模型猜测。
- v2 输入统一要求 `WindowRef`；坐标输入还要求当前 `screenshotId`。
- 动作结果区分 `applied`、`rejected`、`unknown`，禁止用 `isError:false` 代表焦点或点击已经成功。
- `foreground-verified` 为 DSH Computer Use 预设的默认交互模式；保留 `background-best-effort` 作为显式选择。

## 5. 分阶段实施路线

### 当前进度（2026-08-26）

- 已把 Windows runtime 源码、测试、smoke、上游许可证和第三方 notices 正式并入 `runtime/`；独立 runtime checkout 降级为临时上游同步区。
- 已在 Windows runtime 增加 `WindowRef`、`list_windows`、`get_window`、`launch_app`、`activate_window`、`get_window_state`，保留原有 9 个 tools 与 `get_app_state` 兼容入口。
- 已实机验证 DingTalk 精确窗口状态/截图、当前前台窗口激活后验证、多候选 `ambiguous_window` 与陈旧引用 `stale_window`。
- 已在 DSH adapter 增加默认 `foreground-verified` 模式、可选 `background-best-effort`、启动权限配置、统一 runtime env 与 v2/v1 模型指导。
- 已让所有 mutating tools 接受 WindowRef：元素/文本/按键要求最新 `observation_id`，坐标要求最新 `screenshot_id`；动作前精确激活/重验前台，动作后刷新同一窗口并使旧代次失效。
- 已实现首版前台 `SendInput` 鼠标、拖拽、滚轮、Unicode 文本和按键路径，以及 `occluded_by_non_target` 拒绝；本地 WPF 无外发动作 smoke 全通过。
- DSH 插件默认直接启动包内 x64/arm64 原生运行时，移除外部 `open-computer-use` 安装依赖；`runtimeExecutable` 仅保留为开发覆盖项。
- 已建立 `pnpm package:plugin` 单入口：测试、`go vet`、双架构交叉编译、SHA-256 manifest、插件测试、tgz 打包与内容门禁一次完成。
- 已将插件互斥范围从 Session 修正为实际使用 Computer Use 的 Agent turn；turn stopping、Agent disposal 与 Session disposal 都会立即释放占用。
- 已增加不抢焦点、可穿透点击的桌面控制状态条、真实鼠标橙色光环和平滑鼠标轨迹，并在 owner/runtime 退出时自动清理。
- 已完成 M4 首个语义闭环：可聚焦元素暴露 `SetFocus`，焦点按 UIA runtime identity 精确验证，快照返回结构化 `focusedElement`/`selectedElements`/`documentText`，`set_value` 必须读回一致才可返回 `applied`。
- 已把编译期 C# WinRT/D3D 帮助程序嵌入单个 Go runtime，以 Windows.Graphics.Capture 作为截图主路径；完全遮挡的 WPF 窗口仍能读取目标洋红色内容，快照同时暴露捕获来源和诊断降级状态。
- 已声明并验证 Per-Monitor-V2 DPI awareness，快照分别返回显示器有效 DPI、窗口 DPI、物理坐标空间和虚拟桌面边界；视觉坐标按截图／窗口比例映射，越界坐标和窗口移动后的旧截图会在输入前拒绝。
- 已让最小化窗口返回显式不可捕获状态，并验证 `activate_window → fresh get_window_state` 能恢复 WGC 捕获；当前 200% DPI 实机 smoke 通过。
- 已实现模态恢复安全边界：快照返回 `ModalWindows`，已被模态窗口禁用的 owner 会以 `modal_window_required` 拒绝激活并返回精确候选；WinForms owner/modal 实机 smoke 已通过。
- 已实现首版 `expected_postcondition`：支持焦点、值、文本、前台窗口和截图变化验证；不满足时返回 `ActionStatus: unknown`，并已在 WPF 实机 smoke 中覆盖 satisfied/unknown 两条路径。
- 下一切片：完整多屏／负坐标／其他 DPI 机器矩阵、动作风险分类确认、组合／窗口关闭后置条件、真实应用矩阵与正式打包签名。

### M0：基线、工具链与回归夹具

修改范围：

- `runtime/windows/main_test.go`
- `scripts/build-runtime.ps1`
- 新增 Windows fixture app 与 DSH E2E 驱动。

任务：

1. 固定当前 v0.5.0 行为测试，保留后台模式兼容性。
2. 建立 Win32、WPF、Qt、Electron、文本编辑器、模态框、多窗口夹具。
3. 增加 DingTalk、VS Code、记事本、资源管理器和 Office 类真实应用的手工 smoke 场景。
4. 固定 Go、Node、pnpm 与 Windows SDK 版本；当前本机没有 Go，实施时使用工作区隔离工具链或 CI，不直接污染系统环境。
5. 定义 trace 格式：窗口选择、观察 ID、输入路径、前台句柄、焦点元素、后置条件和耗时。

退出门槛：现状失败能够稳定复现；钉钉搜索框用例必须先红。

### M1：窗口身份与生命周期

修改范围：

- `apps/OpenComputerUseWindows/main.go`
- `apps/OpenComputerUseWindows/runtime.ps1`
- `apps/OpenComputerUseWindows/main_test.go`

任务：

1. 实现 `WindowRef`、`list_windows`、`get_window`、`launch_app`。
2. 枚举顶层、owned、modal 和 transient 窗口；建立 hwnd/pid/process-start-time 组合身份。
3. 窗口销毁重建后 generation 必须变化，旧引用返回 `stale_window`。
4. 多候选窗口不自动选择；标题只作提示，不作唯一身份。

退出门槛：100% 拒绝陈旧窗口引用；多窗口 fixture 连续 100 次不误选。

### M2：可靠捕获与坐标系统

任务：

1. 用 Windows.Graphics.Capture 建立窗口截图主路径；PrintWindow/屏幕复制只作诊断回退。
2. 返回主窗口及可见 transient/modal 的有界截图列表、origin、逻辑尺寸和 z-order。
3. 统一物理像素、逻辑像素、窗口客户区和屏幕坐标；进程声明 Per-Monitor-V2 DPI awareness。
4. screenshot ID 与窗口 generation、capture generation 绑定。
5. 检测目标点是否被非目标窗口覆盖，并返回 `occluded_by_non_target`。

退出门槛：100%、125%、150%、200% DPI 与双屏正负坐标组合全部通过；遮挡窗口截图仍可读；旧 screenshot ID 100% 被拒绝。

### M3：前台激活与真实输入引擎

任务：

1. 新增 `activate_window`：恢复最小化窗口、处理 owned/modal 窗口、执行允许范围内的前台激活。
2. 封装 `ShowWindow`、`BringWindowToTop`、`SetForegroundWindow`、线程输入附着与恢复；所有路径必须清理线程附着。
3. 使用 `GetForegroundWindow`、目标 hwnd/pid 和 UIA focused element 验证激活结果。
4. 实现基于 `SendInput` 的鼠标、滚轮、拖拽、键盘和 Unicode 文本路径。
5. 输入前再次校验目标窗口；输入后立即刷新并校验预期变化。
6. 保留 `PostMessage` 为 `background-best-effort`，不再作为强控制默认路径。

退出门槛：交互桌面下 100 次激活成功率至少 99%；不得出现一次输入发送到非目标窗口；失败必须返回 `rejected` 或 `unknown`，不能假成功。

### M4：UIA 语义引擎

任务：

1. 稳定 UIA 树字段、元素 runtime identity、角色、名称、AutomationId、bounds 和 pattern 列表。
2. 点击优先级：Invoke/Selection/Toggle → SetFocus → 验证 → SendInput 坐标回退。
3. 文本优先级：`ValuePattern.SetValue` → 可编辑 hwnd 消息 → 已验证焦点上的 Unicode `SendInput`。
4. 暴露 `focused_element`、`selected_text`、`selected_elements`、`document_text`。
5. 对 Qt/Electron 自绘边界允许视觉坐标路径，但必须绑定 screenshot ID。

退出门槛：钉钉搜索框可自动聚焦并写入联系人；VS Code 编辑器、记事本和 Office 输入夹具全部通过；只填写，不发送。

### M5：动作协调器与恢复状态机

任务：

1. 强制 `observe → one action → refresh → verify`。
2. 为点击、聚焦、输入、滚动和拖拽定义可选后置条件。
3. 发生超时或传输断开时返回 `unknown`；重新观察前禁止重试副作用动作。
4. 处理窗口重建、模态框出现、窗口覆盖、焦点漂移、helper 重启和用户中断。
5. 仅对明确幂等且重新观察后的动作自动重试一次。

退出门槛：故障注入下无双击发送、双重提交或重复文本；helper 崩溃恢复后不复用旧状态。

### M6：DSH 适配、安全与模型体验

修改范围：

- `src/index.ts:24-260`
- `package.json:68`
- `README.md:32-124`

任务：

1. 将依赖切换到签名并固定校验和的补丁 runtime。
2. 增加 `interactionMode`、启动权限、前台输入权限、截图保留和诊断级别配置。
3. 动态协商 runtime capabilities，v1/v2 schema 均可启动，但缺少强控制能力时明确降级。
4. 重写模型指导：唯一窗口选择、优先语义操作、焦点验证、一次一动作、未知结果处理。
5. 将确认策略从粗粒度 tool-call 升级为动作风险分类：发送、删除、上传、购买、权限、敏感数据传输在最终动作前确认。
6. 屏幕、邮件、聊天和文档内容一律视为不可信输入，不能自行授予操作权限。
7. 保留单 runtime ownership，以实际 Agent turn 为租约边界，增加窗口级动作锁与 turn cancellation。

退出门槛：安全测试中的所有高风险最终动作 100% 被确认门阻断；普通观察和无副作用导航无需多余确认。

### M7：质量矩阵、性能与稳定性

测试矩阵：

- GUI 栈：Win32、WPF、WinUI/UWP、Qt、Electron/Chromium、Office。
- 显示：单屏/双屏、负坐标、100/125/150/200% DPI、窗口遮挡、最小化恢复。
- 状态：多窗口、模态框、窗口重建、焦点被抢、helper 重启、锁屏检测。
- 输入：单击/双击/右击、滚轮、拖拽、快捷键、中文/emoji/组合字符、长文本。
- 安全：消息发送、文件删除、上传、权限修改、支付按钮、敏感字段、提示注入。

质量门槛：

- 确定性 fixture 任务成功率 ≥ 99%。
- 100 次焦点与输入压力测试中目标误投递次数 = 0。
- warm capture p95 ≤ 750 ms；单次语义动作加刷新 p95 ≤ 1.5 s。
- stale window/element/screenshot 拒绝率 = 100%。
- 副作用动作故障注入重复执行次数 = 0。
- 所有失败均带机器可读错误码、阶段、目标窗口和恢复建议。

### M8：打包、灰度与上游同步

任务：

1. 插件与内置 runtime 使用同一个发布版本，避免产生第二个需要安装和升级的软件包。
2. 同时生成 x64/arm64 Windows 二进制、SHA-256 manifest 和许可证 notices；正式发布前补 SBOM/provenance。
3. DSH 插件使用 canary → opt-in preset → default preset 三阶段灰度。
4. 保留上一稳定插件包，以整包版本回退；`runtimeExecutable` 只用于诊断，不作为生产部署结构。
5. 使用 `runtime/upstream.json` 记录审核过的上游提交；临时同步 checkout 归档后仍可按提交重新获取，不形成运行时依赖。

退出门槛：干净机器安装、升级、回退和卸载全部通过；固定版本与校验和可重现。

## 6. 验收场景

### 钉钉主场景

1. 从多个窗口中唯一绑定钉钉主窗口。
2. 自动恢复并激活窗口。
3. 定位搜索框，验证焦点进入 Edit 控件。
4. 使用 `set_value` 或已验证焦点输入“郑佳辉”。
5. 刷新后确认文本可见并展示正确搜索结果。
6. 填写消息后停在发送前，触发确认；未确认不得发送。

### 编码场景

1. 唯一绑定 VS Code 窗口。
2. 打开文件、聚焦编辑器、输入中文和代码、保存。
3. 每一步都能通过 UIA、截图或文件外部验证确认结果。
4. 模态保存框出现时切换到对应 WindowRef，不对旧窗口坐标继续点击。

### 任意桌面程序场景

在六类 GUI 技术栈 fixture 中完成“启动 → 选择窗口 → 导航 → 输入 → 验证”，自绘控件允许视觉路径；受保护界面必须明确拒绝。

## 7. 验证策略

### 单元测试

- WindowRef 生命周期、DPI/坐标转换、键名解析、风险分类、后置条件判定、状态失效。
- Win32 API 包装的每个失败分支和资源清理。

### 集成测试

- Go MCP ↔ PowerShell/Windows driver ↔ fixture apps。
- DSH MCP client ↔ runtime capability negotiation ↔ session cancellation。

### E2E

- 钉钉、VS Code、记事本、资源管理器、Office。
- 每个版本至少跑 foreground、DPI、多窗口、模态和故障恢复组合。

### 可观测性

- 每个动作记录 trace id、window generation、observation id、输入路径、before/after focus、后置条件和耗时。
- 默认不持久化截图正文；诊断包需要显式开启并执行敏感信息最小化。

## 8. 主要风险与缓解

- Windows 前台限制：使用显式激活状态机和验证，不把 API 返回值等同成功。
- 权限级别不同：检测完整性级别，不尝试跨越 UAC/安全桌面。
- Qt/Electron UIA 不完整：语义路径失败后使用绑定截图的视觉输入。
- DPI 与多屏误差：全链路统一 logical/physical 坐标并做矩阵测试。
- 模型误判：工具端拒绝 stale 状态、非目标窗口和未确认副作用，不能只依靠提示词。
- 上游快速演进：小补丁集、定期 rebase/sync、协议契约测试。
- 隐私泄露：截图最小化、短生命周期、凭据形状清理和诊断显式授权。

## 9. ADR

### Decision

采用“DSH 薄适配层 + 独立可测试 Windows runtime + MCP v2 窗口协议”，保持现有 v1 工具兼容。

### Drivers

1. 任意桌面程序需要真正的前台输入与视觉回退。
2. 安全和可靠性必须由工具端保证，不能只依赖模型自觉。
3. 需要持续同步 `open-codex-computer-use` 上游。

### Alternatives considered

- 把 runtime 整仓复制进 DSH 插件：拒绝；语言栈、构建和上游同步成本过高。
- 只开启现有两个环境变量：仅能作为短期修补，不能解决窗口身份、真实输入和假成功。
- 完全从零重写：拒绝；会丢掉现有跨平台 MCP、UIA 和打包基础。

### Consequences

- 需要维护一个小型 runtime fork 和一个 DSH adapter fork。
- Windows 构建链新增 Go 工具链与真实桌面 E2E 环境。
- 强控制模式会抢夺用户前台焦点，因此必须显式展示状态、支持立即中断并执行确认策略。

### Follow-ups

M0 完成后再进入 M1；每个里程碑必须通过退出门槛才能合并到下一阶段。首个可用版本以钉钉搜索与输入成功、发送前确认成功为发布闸门。

## 10. Definition of Done

只有同时满足以下条件，才能称为“Codex 级功能等效”：

- 13 个窗口级工具契约完成且保留 v1 兼容。
- 截图、UIA、真实输入、焦点验证和恢复闭环全部上线。
- 钉钉、VS Code 与 GUI 技术栈矩阵达到量化门槛。
- 任何动作不再出现“工具成功但窗口/焦点未变化”的假成功。
- 所有高风险最终动作均在工具端确认门之后。
- 安装、升级、回退、校验和与许可证流程可复现。
- UAC、锁屏、认证、安全软件等禁止边界有自动测试且明确拒绝。
