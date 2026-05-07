# Project Memory

本地优先的个人项目记忆助手。它把本地文件、Markdown/Obsidian、网页捕获、Git 活动和前台应用活动整理成项目上下文，用于生成每日简报和项目问答。

当前状态：dogfood / founder MVP。核心目标不是做通用「第二大脑」，而是回答：

- 我昨天/上周这个项目做到哪了？
- 我看过的资料、网页、会议记录怎么沉淀到项目里？
- 本地文件和活动记录能不能按项目关联起来？
- 每天早上能不能给我一份工作/学习简报？

## 功能

- **本地项目索引**：导入本地文件夹，索引 Markdown、文本、HTML、PDF 和 Git 活动。
- **网页捕获**：手动保存网页标题、URL 和正文摘录；可选自动捕获前台浏览器的标题与 URL。
- **活动元数据记录**：记录前台 app、窗口标题、浏览器 host 和活动类别，不截图、不 OCR。
- **活动 session 聚合**：把 60s 一帧的活动记录聚合成连续工作时段。
- **待归属 Triage**：把未归属的工作 session 手动归到项目，或忽略。
- **每日简报**：基于项目 source 和已归属 work session 生成项目简报。
- **项目问答**：在指定项目范围内问答，引用本地证据片段。
- **隐私边界**：raw `activity_frames` 不进 OpenRouter；只有已归属、`work` 类别、带 `projectID` 的 activity session 会被 materialize 为 source，并经 selector 截断后进入 prompt。

## 技术栈

- Swift 5.10
- SwiftUI / macOS 14+
- Swift Package Manager
- SQLite3
- PDFKit
- OpenRouter Chat Completions API

## 快速启动

```bash
swift build
swift run ProjectMemoryApp
```

如果要开启活动记录功能，需要显式设置环境变量：

```bash
PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1 swift run ProjectMemoryApp
```

如果要开启自动网页捕获功能：

```bash
PROJECT_MEMORY_ENABLE_AUTO_WEB_CAPTURE=1 swift run ProjectMemoryApp
```

两个功能可以同时开启：

```bash
PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1 \
PROJECT_MEMORY_ENABLE_AUTO_WEB_CAPTURE=1 \
swift run ProjectMemoryApp
```

Xcode 运行时需要在 Scheme 里设置环境变量：

1. Product -> Scheme -> Edit Scheme...
2. Run -> Arguments
3. Environment Variables 添加需要的变量
4. Cmd-R 重新启动 app

## 配置

在 app 的 Settings tab 中配置：

- OpenRouter API key
- 活动记录开关
- 排除的 app bundle ID
- 自动化权限状态
- 活动记录清理

本地数据库默认在：

```bash
~/Library/Application Support/ProjectMemory/memory.sqlite
```

## 隐私模型

Project Memory 的默认原则是本地优先：

- 本地文件全文、网页摘录和活动记录保存在本机 SQLite。
- OpenRouter API key 存在 Keychain。
- Prompt 只发送 selector 选出的截断片段。
- `activity_frames` 原始帧永远不直接进入 prompt。
- 浏览器 activity session 只暴露 host，不发送 URL path/query。
- unassigned、ignored、non-work activity session 不会 materialize 成 prompt source。

## 测试

```bash
swift test
```

当前测试覆盖重点：

- 文件导入与 source 去重
- prompt 截断和隐私边界
- URL deny-list
- activity metadata capture
- session aggregation
- project activity rules
- activity session materialization gate
- Triage 手工归属持久性

针对 prompt 隐私边界：

```bash
swift test --filter PromptPathPrivacyGuardsTests
swift test --filter PromptPathSentinelTests
```

## Dogfood Smoke Test

Phase 2 的手动 smoke test 在：

[docs/superpowers/runbooks/2026-05-07-phase-2-smoke-test.md](docs/superpowers/runbooks/2026-05-07-phase-2-smoke-test.md)

常用检查：

```bash
sqlite3 "$HOME/Library/Application Support/ProjectMemory/memory.sqlite" \
  "SELECT observed_at, bundle_id, app_name, category, browser_url FROM activity_frames ORDER BY observed_at DESC LIMIT 10;"
```

```bash
sqlite3 "$HOME/Library/Application Support/ProjectMemory/memory.sqlite" \
  "SELECT id, started_at, ended_at, app_name, browser_host, category, assignment_status, project_id FROM activity_sessions ORDER BY ended_at DESC LIMIT 10;"
```

## 文档

- [MVP Design](docs/superpowers/specs/2026-05-06-project-memory-design.md)
- [Activity Metadata Capture Design](docs/superpowers/specs/2026-05-07-activity-metadata-capture-design.md)
- [Phase 2 Activity Sessions Design](docs/superpowers/specs/2026-05-07-phase-2-activity-sessions.md)
- [Eval Design](docs/eval/eval-design.md)
- [Eval Rubrics](docs/eval/rubrics.md)

## 当前限制

- 仍处于本地 dogfood 阶段，没有打包、签名、notarization。
- 活动记录需要显式环境变量和 Settings toggle 双重开启。
- OCR lane 尚未实现；当前不截图、不识别屏幕文字。
- Triage UI 当前只做归属/忽略，不支持从 session 一键创建规则。
- Activity session 分类主要依赖 bundle ID 和 browser host 规则，后续需要根据真实 dogfood 数据持续补规则。
