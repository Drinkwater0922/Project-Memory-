# Phase 2 Activity Sessions Smoke Test Runbook

目标：验证 Phase 2 的活动 session 聚合、待归属 UI、手工归属持久性、Brief/Q&A 接入，以及隐私边界。

前置条件：
- Phase 1 activity metadata capture 已能写入 `activity_frames`。
- 启动时设置 `PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1`。
- Settings 里已启用「活动记录」。
- 至少已有一个 Project，例如 `project-memory`。

## Step 0: 启动与清理

Xcode 启动路径：
1. Product -> Scheme -> Edit Scheme...
2. Run -> Arguments -> Environment Variables
3. 添加 `PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1`
4. Cmd-R 启动 app

Terminal 启动路径：

```bash
PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1 swift run ProjectMemoryApp
```

可选：清掉旧活动帧，避免历史数据干扰：

```bash
sqlite3 "$HOME/Library/Application Support/ProjectMemory/memory.sqlite" \
  "DELETE FROM activity_session_frames; DELETE FROM activity_sessions; DELETE FROM activity_frames;"
```

## Step 1: 生成 activity frames

1. 打开 Cursor 或 Xcode，停留 3 分钟以上，让 60s tick 产生至少 3 帧。
2. 打开 Chrome / Safari 到 `https://github.com` 或 `https://swift.org`，停留 3 分钟以上。
3. 等到下一次 60s tick 后，回到 ProjectMemoryApp。

用 SQLite 验证：

```bash
sqlite3 "$HOME/Library/Application Support/ProjectMemory/memory.sqlite" \
  "SELECT observed_at, bundle_id, app_name, category, browser_url FROM activity_frames ORDER BY observed_at DESC LIMIT 10;"
```

预期：
- 能看到 Cursor/Xcode 或浏览器对应 frame。
- `category` 对工作 app / 工作 URL 应为 `work`。
- 浏览器 URL deny-list 命中的页面不应写入 frame。

## Step 2: 待归属 tab

1. 打开顶部「待归属」tab。
2. 确认列表出现刚才的 work sessions。
3. tab badge 数量应等于 `unassigned + work` session 行数。
4. 浏览器 session 只显示 host，例如 `github.com`，不显示 URL path/query。

辅助查询：

```bash
sqlite3 "$HOME/Library/Application Support/ProjectMemory/memory.sqlite" \
  "SELECT id, started_at, ended_at, app_name, browser_host, category, assignment_status, project_id FROM activity_sessions ORDER BY ended_at DESC LIMIT 10;"
```

预期：
- 新 session 初始为 `assignment_status = unassigned`。
- `frame_count` 应大于 1；单帧噪音不应生成 session。

## Step 3: 手工归属 / 忽略 / 撤销忽略

1. 对 Cursor/Xcode session 点「归属到项目」，选择 `project-memory`。
2. 该行应从主列表消失。
3. 对一个浏览器 session 点「忽略」。
4. 该行应进入「已忽略」折叠区。
5. 展开「已忽略」，点「撤销忽略」。
6. 该行应回到主列表。

SQLite 验证：

```bash
sqlite3 "$HOME/Library/Application Support/ProjectMemory/memory.sqlite" \
  "SELECT app_name, assignment_status, assignment_source, project_id FROM activity_sessions ORDER BY ended_at DESC LIMIT 10;"
```

预期：
- 手工归属：`assignment_status = manualAssigned`，`assignment_source = manual`，`project_id` 非空。
- 忽略：`assignment_status = ignored`，`assignment_source = manual`，`project_id` 为空。
- 撤销忽略：状态回到 `unassigned`，后续 pipeline 可重新按规则归属。

## Step 4: 手工归属持久性

1. Quit app。
2. 重新启动 app。
3. 打开「待归属」tab。
4. 已归属的 session 不应重新出现在待归属列表。

SQLite 验证：

```bash
sqlite3 "$HOME/Library/Application Support/ProjectMemory/memory.sqlite" \
  "SELECT id, assignment_status, assignment_source, project_id FROM activity_sessions WHERE assignment_source = 'manual';"
```

预期：
- `manualAssigned` / `ignored` 决策保留。
- 后续规则变化不应覆盖 manual 决策。

## Step 5: Brief 集成

1. 打开 Today。
2. 点击「Generate Brief」。
3. 观察生成结果是否引用已归属的 work activity session，例如应用名、时间窗、持续时间、host。

隐私预期：
- 只有 assigned + work session 会 materialize 成 `MemorySource(kind = activitySession)`。
- unassigned / ignored / non-work session 不应出现在 brief。
- 浏览器 session 只应包含 host，不应包含 URL path/query。

辅助查询：

```bash
sqlite3 "$HOME/Library/Application Support/ProjectMemory/memory.sqlite" \
  "SELECT kind, title, path, url, extracted_text FROM sources WHERE kind = 'activitySession' ORDER BY modified_at DESC LIMIT 5;"
```

预期：
- `url` 应为空。
- `path` 格式为 `activity-sessions/<session-id>`。
- browser session 的 `extracted_text` 只含 host，不含 title samples 或 URL path/query。

## Step 6: Q&A 集成

1. 到 Ask tab，选择 `project-memory`。
2. 提问：「我今天在这个项目上做了什么？」
3. 预期回答可以引用 assigned work activity session。
4. 再选择 No Project 或清空 project scope，问同样问题。
5. 预期无 project scope 时不带 activity session 进入 prompt。

这是硬隐私边界：Q&A 的 `.activitySession` 候选必须满足 `source.projectID == selectedProjectID`。

## Step 7: 长 snippet 截断标记

该步骤只在能构造长 session summary 时验证。

1. 构造一个 non-browser work session，title samples 总长度超过 800 字。
2. 手工归属到项目。
3. 生成 brief。
4. 预期 activity snippet 被截断，并出现：

```text
[内容已截断，仅发送相关片段]
```

短 session 不要求出现截断标记。

## Step 8: 隐私 guard

运行：

```bash
swift test --filter PromptPathPrivacyGuardsTests
swift test --filter PromptPathSentinelTests
```

源码扫描：

```bash
grep -rn "ActivityFrame\|activity_frames" \
  Sources/ProjectMemoryCore/BriefGenerator.swift \
  Sources/ProjectMemoryCore/AnswerEngine.swift
```

```bash
grep -rn "extractedText" \
  Sources/ProjectMemoryCore/BriefGenerator.swift \
  Sources/ProjectMemoryCore/AnswerEngine.swift
```

预期：
- 两组 privacy tests 全绿。
- 两个 `grep` 都没有输出。
- Prompt path 只读 `SelectedSourceSnippet.snippet`，不直接读 `MemorySource.extractedText`。

## Step 9: Coverage gate

最终运行：

```bash
swift build
swift test
```

预期：
- `swift build` clean，无 deprecated warning。
- `swift test` 全绿。
- 测试数量应在 150+；当前 Phase 2 目标是 186+。

## 失败定位

- Triage 没有 session：先查 `activity_frames` 是否有 2 帧以上同 identity 数据。
- Session 生成但不进 brief：查 `activity_sessions.assignment_status`、`category`、`project_id`，三条 gate 缺一不可。
- 手工归属丢失：查 `assignment_source` 是否为 `manual`，以及 pipeline window 是否覆盖该 session。
- Q&A 无 project scope 却出现 activity：这是 blocker，说明 selector 的 activity filter 失效。
- Prompt 出现 raw `extractedText` sentinel：这是 blocker，说明 prompt path 绕过了 `SelectedSourceSnippet.snippet`。
