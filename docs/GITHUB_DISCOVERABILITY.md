# GitHub 可发现性审查

审查日期：2026-08-27

目标仓库：`zjh02249/dsh-plugin-computer-use`

## 结论

在仓库尚未创建、尚未公开之前，GitHub 用户当然无法搜索到它。完成公开发布、填写英文描述并设置 Topics 后，本项目对以下**目标明确的查询**预计具有较好的可发现性：

- `deepseek harness computer use`
- `dsh computer use`
- `dsh plugin desktop automation`
- `windows computer use mcp`
- `deepseek harness windows automation`

但“精确仓库名”存在竞争：GitHub 已有原始仓库 [`valkia/dsh-plugin-computer-use`](https://github.com/valkia/dsh-plugin-computer-use)，并且目前对 `dsh-plugin-computer-use in:name` 的搜索会首先命中它。因此新仓库不能假设自己会因为同名而排在第一位。最重要的区分手段是：

1. 仓库 owner `zjh02249`；
2. 明确说明这是独立维护的增强衍生版；
3. 英文 description 和准确 Topics；
4. README 中可验证的 Windows 增强功能；
5. 持续、真实的 Releases 和维护活动。

综合判断：

| 场景 | 预计效果 |
|---|---|
| 用户已知道完整地址 `zjh02249/dsh-plugin-computer-use` | 很容易找到 |
| 搜索 `dsh-plugin-computer-use` | 中等；会与原始同名仓库竞争 |
| 搜索 `deepseek harness computer use` | 公开并完成 Topics 后较好 |
| 搜索泛化词 `computer use` | 较弱；该词竞争范围很大 |
| 通过 Topics 浏览 | 设置 Topics 后较好 |
| 通过站外分享链接进入 | README 双语入口清晰；后续可增加 Social Preview |

GitHub 没有公开完整的仓库搜索排名公式，因此以上“预计效果”是基于当前搜索结果和公开字段做出的判断，不是排名保证。

## GitHub 官方明确说明的搜索字段

GitHub 的仓库搜索文档明确说明：

- 不写 `in:` 限定符时，仓库搜索默认匹配**仓库名称、描述和 Topics**；
- `in:name` 可只搜索仓库名；
- `in:description` 可搜索描述；
- `in:topics` 可搜索 Topics；
- `in:readme` 可搜索 README 内容。

来源：[GitHub Docs — Searching for repositories](https://docs.github.com/en/search-github/searching-on-github/searching-for-repositories#search-by-repository-name-description-or-contents-of-the-readme-file)

这意味着普通搜索中，仓库 description 和 Topics 比在 README 深处堆积关键词更直接。README 仍然会影响 `in:readme` 查询和用户进入仓库后的判断，但不应通过重复关键词制造噪声。

## Topics 的官方作用和限制

GitHub 明确表示，Topics 用于帮助人们发现项目、浏览特定领域、寻找可贡献的项目和同类解决方案。Topic 还会显示在仓库首页，并链接到同 Topic 的仓库列表。

Topics 必须：

- 使用小写字母、数字和连字符；
- 每个 Topic 不超过 50 个字符；
- 每个仓库最多 20 个 Topics。

来源：[GitHub Docs — Classifying your repository with topics](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/classifying-your-repository-with-topics)

## README、许可证和社区资料

GitHub 建议 README 说明项目用途、价值、如何开始、如何获得帮助以及维护者信息。README 通常也是访问者进入仓库后首先阅读的内容。

来源：[GitHub Docs — About READMEs](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)

GitHub 的 public repository community profile 会检查 README、LICENSE、CONTRIBUTING、CODE_OF_CONDUCT 等资料。这些资料提高开源项目的可信度和贡献体验，但 GitHub 官方没有说明它们会直接提升普通仓库搜索排名。

来源：[GitHub Docs — About community profiles for public repositories](https://docs.github.com/en/communities/setting-up-your-project-for-healthy-contributions/about-community-profiles-for-public-repositories)

## Social Preview 的边界

GitHub 支持为公开仓库上传 Social Preview 图片；它主要影响仓库链接在社交平台上的展开效果和项目识别度。GitHub 官方没有把 Social Preview 描述为站内仓库搜索排名因素。

建议尺寸至少 640×320，最佳为 1280×640，PNG/JPG/GIF 且小于 1 MB。

来源：[GitHub Docs — Customizing your repository's social media preview](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview)

## 当前项目检查表

| 项目 | 当前状态 | 评价与处理 |
|---|---|---|
| 仓库名称 | `dsh-plugin-computer-use` | 核心词准确，但与原始仓库同名；通过 owner、描述和项目关系说明区分 |
| 仓库公开状态 | 尚未创建 | 创建为 public 后才可进入 GitHub 索引 |
| GitHub Description | 已准备英文描述 | 同时包含 DeepSeek Harness、DSH、Windows Computer Use、desktop automation、UI Automation 和 MCP |
| 中文 README | `README.md` 完整 | 顶部提供醒目的英文切换入口 |
| 英文 README | `README.en.md` 完整 | 覆盖安装、兼容矩阵、已实现/未实现、配置、构建和安全边界 |
| 旧中文链接 | `README.zh.md` | 作为兼容入口，指向中文主文档和完整英文文档 |
| 项目关系 | 已明确 | 链接原始 `valkia` 仓库，说明独立增强衍生关系并保留 DeepSeek MIT 归属 |
| Topics | 尚未设置 | 仓库创建后立即设置推荐 Topics |
| License | MIT 已存在 | 保留 DeepSeek Copyright 和 runtime 第三方声明 |
| Releases | 自动化已准备 | 标签触发构建和资产上传；历史标签回填版本页 |
| Changelog | 已存在 | 展示 0.2.0、0.6.0、0.7.0、0.8.0 的差异 |
| Community Profile | 部分完成 | README/License 已有；CONTRIBUTING、CODE_OF_CONDUCT 和 issue templates 可作为后续增强 |
| Social Preview | 未设置 | 不影响本次发布，可在发布后补一张 1280×640 项目图 |

## 推荐 GitHub Description

```text
DeepSeek Harness / DSH plugin for safe Windows Computer Use, desktop automation, UI Automation, and MCP tools
```

该描述短、准确，并覆盖普通 GitHub 搜索默认检查的 description 字段。它没有使用“full Codex parity”或“production ready”等当前无法证明的营销表述。

## 推荐 Topics

建议首发使用以下 16 个，少于 GitHub 20 个上限：

```text
deepseek
deepseek-harness
dsh
dsh-plugin
computer-use
desktop-automation
desktop-control
windows
windows-automation
mcp
model-context-protocol
ui-automation
uiautomation
accessibility
ai-agent
open-computer-use
```

暂不推荐添加 `computer-vision`、`ocr`、`macos`、`linux` 或 `production-ready`，因为这些能力当前尚未实现或完成验证。

## 发布后核验查询

GitHub 完成索引可能需要时间。发布并设置 Topics 后，应依次核验：

```text
dsh-plugin-computer-use in:name
"DeepSeek Harness" "Computer Use" in:name,description,topics
"desktop automation" dsh in:description,topics
topic:deepseek-harness topic:computer-use
zjh02249/dsh-plugin-computer-use
```

还应检查：

- 仓库首页是否显示英文 description；
- Topics 是否全部可点击；
- README 顶部中英文切换是否正确；
- License 是否被 GitHub 识别为 MIT；
- Releases 是否显示全部版本和 `0.8.0` 安装包；
- 项目关系说明是否在首屏附近可见。

## 发布后的进一步提升

以下项目有助于信任、贡献和站外传播，但不是本次公开发布的硬阻塞项：

1. 增加 `CONTRIBUTING.md`、`CODE_OF_CONDUCT.md` 和 issue templates；
2. 制作 1280×640 Social Preview；
3. 在真实功能完成后发布节奏清晰的版本，不制造无内容版本；
4. 公开可复现的安装和 smoke-test 证据；
5. 在获得许可并准备好维护反馈后，再向相关 DSH awesome list 提交项目条目。
