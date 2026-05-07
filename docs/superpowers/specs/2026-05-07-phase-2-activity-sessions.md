# Phase 2 — Activity Sessions, Project Attribution & Brief Integration

日期：2026-05-07
作者：Claude（研发 SE + 评测工程师）+ user（产品决策）
状态：等 user spec review

## 0. 上下文与前置

Phase 1（`2026-05-07-activity-metadata-capture-design.md`）已经把 raw `ActivityFrame` 写入 `activity_frames` 表，硬隔离在 brief / Q&A / OpenRouter 之外。Phase 2 在此底料上做三件事：

1. **聚合**：把 frames 切成 `ActivitySession`，作为对外可解释的最小单位
2. **归属**：让 session 落到具体 `Project`（rule 自动 + 用户 manual）
3. **整合**：把已归属的 session 经 selector 截断后进 brief / Q&A，但不破坏 Phase 1 隐私边界

## 1. 问题与目标

**问题**：Phase 1 的 frame 是 60s 一帧的离散点，对用户毫无意义。"我今天在 project-memory 上花了 1h 16m"这种判断，frame 本身回答不了；对外 LLM 暴露 frame 流也是隐私灾难。

**目标**：

- 提供 `ActivitySession`（连续工作时段）作为活动的最小可解释单元
- 提供 `Project` 自动归属机制（host / bundleID / title 规则）+ 用户 manual triage 兜底
- 让已归属、已类目化（`category == .work`）的 session 经截断后进 brief 与（项目 scope 下的）Q&A
- 不破坏 Phase 1 任何隐私边界；不让 raw frame 走出 SQLite

**非目标（Phase 2 明确不做）**：

- 截图 / OCR / Vision（仍是 Phase 1.5）
- LLM-based session 分类
- 跨设备同步
- 用户在 triage UI 编辑 rule（rule 编辑统一在设置页）
- 从 triage 直接创建 rule（Phase 2.5 backlog）
- 启用 SQLite `PRAGMA foreign_keys=ON`（独立工作）

## 2. Hard rails（不可破）

整个 Phase 2 实施过程必须维持以下三条边界，任何 PR 越线视为隐私回归：

1. **`activity_frames` 数据 NEVER 直接进 OpenRouter**。它只能通过 Phase 2 的 aggregator → resolver → reconciler → `MemorySource(kind: .activitySession)` 这条管道，且仅当 `assignmentStatus ∈ {.ruleAssigned, .manualAssigned}` 且 `category == .work` 且 `projectID != nil` 时才 materialize 成 source（**三条同时满足**，缺一不可）。
2. **聚合管道必须有显式隐私 gate**：deny-list（沿用 Phase 1 host-label exact match）、category gate、frameCount gate（drop `frameCount == 1` 的 draft，避免单帧噪音）、URL/title sanitization、source snippet cap。
3. **用户必须能看见并纠正归属**：每个 unassigned/.work session 必须出现在 Triage UI；用户的 manual 决策不可被后续 rule 重算覆盖。

## 3. Decision Log（产品/架构 fork）

六个 Q + §1/§2/§3/§4/§5 设计 fork 已对齐：

| # | 问题 | 决定 |
|---|---|---|
| Q1 | rule 形态 | **(d) 规则优先 + manual fallback** — 规则表 + manual triage 兜底；规则按 kind（urlContains / titleContains / bundleIDEquals）分组，bundleID 是宽匹配 |
| Q2 | session 切分 identity | **bundleID + browser host** — 同 host 内 path 变化不断；非浏览器仅看 bundleID。`browserURL` normalize 后取 host |
| Q3 | materialization 条件 | **`(.ruleAssigned ∨ .manualAssigned) ∧ .work ∧ projectID != nil`** — 三条同时满足；unassigned/ignored/non-work/无项目永不 materialize |
| Q4 | session.id 生成 | **`session.id = firstFrame.id`** — 不做 hash，不做 UUID 生成 |
| Q5 | Triage 操作 | **assign / ignore / undoIgnore only** — 不允许从 triage 改 category 或编辑 rule；assignment 存在 `activity_sessions` 行内（非独立 join 表） |
| Q6 | Selector 配额 | **硬配额（caps not minimums）** — brief 4/12, Q&A 2/8, 400 chars/source, brief 总 900 / answer 总 600 |
| §1 | 三层切分 | aggregator 不持 rules（仅切 session）、resolver 持 rules + preserved（assignment 决策层）、reconciler 仅 replaceWindow（写库 + materialization 门）；orchestrator 在 App 层 |
| §2 | ID 与路径 | session.id 与 MemorySource.id **分离**；source path = `"activity-sessions/<session.id>"`；`replaceActivitySession` 是原子写入 API |
| §3 | 归属算法细节 | urlContains/titleContains 扫**所有** relatedFrames（不止 first frame）；pipeline 入口先建 frameIDs Dictionary 避免 O(n²)；reconciler 双重清理（staleIds + `fetchActivitySessionSources(window)` 兜底孤儿） |
| §4 | Selector 接口 | 新 `SelectedSourceSnippet` 类型；**所有** SourceKind 走 snippet（不只是 activity）；prompt 路径禁止读 `source.extractedText`；Q&A 无 selectedProjectID 时 activitySession 全排除 |
| §5 | Manual 持久性 | 通过 pipeline preserved map（不通过 SQL 保留谓词）；`activity_sessions` 单表承载 assignment（无独立 join/assignment 表） |

## 4. 架构

```
┌──────────────────────────────────────────────────────────────────────┐
│  SessionPipeline (ProjectMemoryApp, @MainActor)                       │
│  ─────                                                               │
│  唯一 orchestrator。不知道 SQL；不知道纯逻辑细节。                    │
│                                                                      │
│  run(window: DateInterval):  // 详细伪代码见 §6.4                     │
│    1. preserved = store.fetchActivitySessionAssignments(window)      │
│       // 返回 [PreservedAssignment]；pipeline 内转 Dictionary by id   │
│    2. frames = store.fetchActivityFrames(since:until:)               │
│       framesByID = Dictionary(uniqueKeysWithValues:                  │
│                                frames.map { ($0.id, $0) })           │
│    3. drafts = SessionAggregator.aggregate(frames)                   │
│    4. rules = store.fetchRules()                                     │
│    5. resolved = drafts.map { resolver.resolve(...) }                │
│       // preserved[draft.id]?  + framesByID 抽 relatedFrames         │
│    6. ActivitySessionReconciler.replaceWindow(                       │
│         since:..., until:..., with: resolved, in: store)             │
└──────────────────────────────────────────────────────────────────────┘
        │                                                  │
        ▼                                                  ▼
┌──────────────────────────────┐    ┌──────────────────────────────────┐
│  Core (pure, no I/O)         │    │  Core (side-effects, store-bound)│
│  ─────                       │    │  ─────                           │
│  SessionAggregator           │    │  ActivitySessionReconciler       │
│   .aggregate([Frame])        │    │   .replaceWindow(since:until:    │
│   → [SessionDraft]           │    │                  with:in:)       │
│                              │    │                                  │
│  AssignmentResolver          │    │   - 读 staleIds                  │
│   .resolve(                  │    │   - delete sessions + join       │
│     draft, rules,            │    │   - fetchActivitySessionSources  │
│     preserved,               │    │     (window) 兜底删孤儿 sources  │
│     relatedFrames)           │    │   - 写新 sessions + join         │
│   → ResolvedSession          │    │   - materialize eligible 为      │
│                              │    │     MemorySource(.activitySession)│
└──────────────────────────────┘    └──────────────────────────────────┘
                                              │
                                              ▼
                                    ┌─────────────────────────────────┐
                                    │  MemoryStore (existing)         │
                                    │  + activity_sessions            │
                                    │  + activity_session_frames      │
                                    │  + memory_sources(.activitySession)│
                                    └─────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  Brief / Q&A path（修改）                                             │
│                                                                      │
│  candidates: [MemorySource]  ──► SourceSnippetSelector              │
│                                  .selectForBrief / .selectForAnswer  │
│                                  applies ActivitySessionCaps         │
│                                ──► [SelectedSourceSnippet]           │
│                                ──► BriefGenerator / AnswerEngine     │
│                                    （仅读 snippet.snippet，          │
│                                     禁止读 source.extractedText）    │
│                                ──► OpenRouterClient                  │
└──────────────────────────────────────────────────────────────────────┘
```

三层职责严格切：

- **SessionAggregator**：纯切 session。**不**持有 rules，**不**做归属决策。输入 frames，输出 drafts（每个 draft 持 `frameIDs: [UUID]`）
- **AssignmentResolver**：纯归属。先看 preserved（manual 决策），未命中再跑 rules。返回 `ResolvedSession`
- **ActivitySessionReconciler**：纯写库 + materialization 门。仅做 `replaceWindow`
- **SessionPipeline**：App 层 orchestrator，仅做装配；不知道 SQL，不知道纯逻辑细节

## 5. 数据模型

### 5.1 Core 类型（新增）

```swift
public enum AssignmentStatus: String, Codable {
    case unassigned
    case ruleAssigned
    case manualAssigned
    case ignored
}

public struct ProjectActivityRule: Identifiable, Codable, Equatable {
    public let id: UUID
    public let projectID: UUID
    public let kind: Kind
    public let pattern: String       // 仅 trim 后存储（不预先 lowercase / sanitize）；
                                     // resolver 在匹配时按 kind 做 normalize（见下方注释）
    public let isEnabled: Bool
    public let createdAt: Date

    public enum Kind: String, Codable {
        // resolver 匹配规则（pattern 始终是 trim 后原值）：
        //
        // urlContains:
        //   normalizedURL = browserURL 去 query/fragment + host lowercase
        //   命中 = normalizedURL.contains(pattern.lowercased())
        //
        // titleContains:
        //   normalizedTitle = TextSanitizer.stripInvisibleControls(windowTitle).lowercased()
        //   命中 = normalizedTitle.contains(pattern.lowercased())
        //
        // bundleIDEquals:
        //   命中 = pattern == draft.bundleID（**严格大小写敏感** — macOS bundle ID 区分大小写）
        case urlContains
        case titleContains
        case bundleIDEquals
    }
}

public struct ActivitySessionDraft: Equatable {
    public let id: UUID                  // = firstFrame.id
    public let startedAt: Date
    public let endedAt: Date
    public let bundleID: String
    public let appName: String
    public let browserHost: String?      // normalize 后的 host
    public let category: ActivityCategory
    public let titleSamples: [String]    // 见下方 §6.1 步骤 4：max 5、first-seen 顺序、
                                         // 已 sanitize（stripInvisibleControls）、去重
    public let frameCount: Int
    public let frameIDs: [UUID]
}

public struct ResolvedActivitySession: Equatable {
    public let draft: ActivitySessionDraft
    public let assignmentStatus: AssignmentStatus
    public let projectID: UUID?
    public let assignmentSource: String?  // "manual" | "rule:<uuid>" | nil
}

public struct PreservedAssignment: Equatable {
    public let sessionID: UUID
    public let assignmentStatus: AssignmentStatus  // .manualAssigned 或 .ignored
    public let projectID: UUID?
}

/// `activity_sessions` 行的 1:1 投影。Triage UI / 项目页用。
public struct PersistedActivitySession: Identifiable, Equatable, Codable {
    public let id: UUID
    public let startedAt: Date
    public let endedAt: Date
    public let bundleID: String
    public let appName: String
    public let browserHost: String?
    public let category: ActivityCategory
    public let assignmentStatus: AssignmentStatus
    public let projectID: UUID?
    public let assignmentSource: String?  // "manual" | "rule:<uuid>" | nil
    public let titleSamples: [String]
    public let frameCount: Int
}
```

### 5.2 SQLite Schema（新增表）

```sql
CREATE TABLE IF NOT EXISTS activity_sessions (
    id TEXT PRIMARY KEY,                  -- = first_frame.id (UUID string)
    started_at TEXT NOT NULL,             -- ISO8601
    ended_at TEXT NOT NULL,               -- ISO8601
    bundle_id TEXT NOT NULL,
    app_name TEXT NOT NULL,
    browser_host TEXT,                    -- nullable: nil 表示非浏览器或浏览器 url 不可读
    category TEXT NOT NULL,               -- 'work' | 'socialMedia' | 'chat' | 'other'
    assignment_status TEXT NOT NULL,      -- 'unassigned' | 'ruleAssigned' | 'manualAssigned' | 'ignored'
    project_id TEXT,                      -- nullable: assignment_status != .ruleAssigned/.manualAssigned 时为 nil
    assignment_source TEXT,               -- nullable: "manual" | "rule:<uuid>" | nil
    title_samples_json TEXT NOT NULL,     -- JSON array<string>，UI 截断显示
    frame_count INTEGER NOT NULL
);

-- Triage 列表与 window 重算大量按 ended_at 过滤/排序
CREATE INDEX IF NOT EXISTS idx_sessions_ended_at ON activity_sessions(ended_at DESC);

-- preserved fetch 谓词精确覆盖：
--   WHERE assignment_source='manual'
--     AND assignment_status IN ('manualAssigned','ignored')
--     AND window 重叠
-- 复合索引顺序：source（最 selective，仅 'manual'/'rule:<uuid>'/nil）→ status → ended_at
CREATE INDEX IF NOT EXISTS idx_sessions_source_status_ended_at
    ON activity_sessions(assignment_source, assignment_status, ended_at DESC);

-- Triage 列表：按 status 过滤 + 按 ended_at DESC 排序
CREATE INDEX IF NOT EXISTS idx_sessions_status_ended_at
    ON activity_sessions(assignment_status, ended_at DESC);

-- 项目页时间线："过去 N 天该项目的 sessions"
CREATE INDEX IF NOT EXISTS idx_sessions_project_ended_at
    ON activity_sessions(project_id, ended_at DESC);

-- session ↔ frame 关系。无决策语义，纯 join。
-- SQLite foreign_keys not enabled in this codebase; cascade is application-enforced
-- via reconciler.replaceWindow.
CREATE TABLE IF NOT EXISTS activity_session_frames (
    session_id TEXT NOT NULL,
    frame_id TEXT NOT NULL,
    PRIMARY KEY (session_id, frame_id)
);

CREATE INDEX IF NOT EXISTS idx_session_frames_frame ON activity_session_frames(frame_id);

CREATE TABLE IF NOT EXISTS project_activity_rules (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL,
    kind TEXT NOT NULL,                   -- 'urlContains' | 'titleContains' | 'bundleIDEquals'
    pattern TEXT NOT NULL,                -- trim 后存储；resolver 按 kind normalize/match（详见 §5.1 Kind 注释 / §6.2）
    is_enabled INTEGER NOT NULL,          -- 0 / 1
    created_at TEXT NOT NULL              -- ISO8601
);

CREATE INDEX IF NOT EXISTS idx_rules_project ON project_activity_rules(project_id);
CREATE INDEX IF NOT EXISTS idx_rules_kind_enabled ON project_activity_rules(kind, is_enabled);
```

**没有** `activity_session_assignments` 表。**没有** `decided_by` 字段。Manual / rule 决策通过 `assignment_source` 字段值区分。

### 5.3 新增 MemoryStore APIs（汇总）

Phase 2 在 `MemoryStore` 上新增以下方法（具体签名实施时定型）：

```swift
// activity_sessions
func fetchActivitySessionIDs(since: Date, until: Date) throws -> [UUID]
func fetchActivitySessions(since: Date, until: Date) throws -> [PersistedActivitySession]
func fetchActivitySessionAssignments(since: Date, until: Date) throws -> [PreservedAssignment]
//   SQL 谓词：assignment_source = 'manual'
//             AND assignment_status IN ('manualAssigned', 'ignored')
//             AND ended_at >= since AND started_at <= until
func deleteActivitySessions(ids: [UUID]) throws  // 同时清 activity_session_frames 行
func writeActivitySession(_ session: ResolvedActivitySession) throws
func updateActivitySessionAssignment(
    sessionID: UUID,
    assignmentStatus: AssignmentStatus,
    projectID: UUID?,
    assignmentSource: String?
) throws

// activitySession sources lookup + 孤儿兜底
// 现有 store 仅有按 id 删除；这里补 find by path 用于路径稳定 lookup
func findSourceByPath(_ path: String) throws -> MemorySource?
func fetchActivitySessionSources(since: Date, until: Date) throws -> [MemorySource]

// rules
func fetchRules() throws -> [ProjectActivityRule]
func upsertRule(_ rule: ProjectActivityRule) throws
func deleteRule(id: UUID) throws
```

`fetchActivityFrames(category:project:since:until:limit:)` 在 Phase 1 已存在；pipeline 调用形如 `store.fetchActivityFrames(since: window.start, until: window.end)`，不重复列入 Phase 2 新 API。

### 5.4 `SourceKind` enum 扩展（新增 case）

Phase 1 / Phase A 已有的 `SourceKind` 枚举：

```swift
public enum SourceKind: String, Codable, CaseIterable {
    case markdown
    case pdf
    case html
    case text
    case gitCommit
    case webCapture
    case unsupported
}
```

Phase 2 新增：

```swift
case activitySession
```

`Codable` raw value 即 `"activitySession"`；DB 写入直接使用此字符串。所有 `switch` 现有点必须更新（编译期会报错防漏）。

### 5.5 MemorySource 复用

`MemorySource(kind: .activitySession)` 复用现有表与字段：

- `id`：与 `activity_sessions.id` **不同**（独立 UUID）
- `path`：`"activity-sessions/<session.id>"` —— 稳定 lookup key
- `projectID`：来自 ResolvedActivitySession.projectID
- `extractedText`：`makeExtractedText(session)` 输出（见 §6.5）
- `modifiedAt`：session.endedAt
- `indexedAt`：write 时

材化 gate（hard，三条同时满足）：仅当 `assignmentStatus ∈ {.ruleAssigned, .manualAssigned} ∧ category == .work ∧ projectID != nil` 时 reconciler 写入 MemorySource；其他情形（含 unassigned、ignored、non-work、`projectID == nil` 的任意组合）仅写 `activity_sessions` 行。

## 6. Core Pipeline 算法

### 6.1 SessionAggregator

```swift
public enum SessionAggregator {
    public static func aggregate(_ frames: [ActivityFrame]) -> [ActivitySessionDraft]
}
```

5 步算法（单次 pass）：

1. 输入 frames 按 `observedAt asc` 排序
2. 计算 identity key: `(bundleID, normalizedBrowserHost)`，其中 `normalizedBrowserHost` 来自 `browserURL` 经 host extract + lowercase（去 query/fragment）；非浏览器 frame 的 host 设为 nil
3. 单次 pass 切片：相邻 frame identity key 相同 **且** 时间间隔 ≤ 5min → 同 session；否则切
4. 每 session 计算 startedAt = 第一 frame.observedAt，endedAt = 最后 frame.observedAt，frameCount = frame 数量，frameIDs 保序，titleSamples 按下列规则生成（Q2 锁定）：
   - 遍历 session frames 的 `windowTitle`（compactMap 去 nil）
   - 每个 title `TextSanitizer.stripInvisibleControls(_)` 然后 `trimmingCharacters(in: .whitespacesAndNewlines)`
   - 跳过 sanitize 后为空字符串的项
   - 按 first-seen 顺序去重
   - 取前 **5** 个
5. 丢弃 `frameCount == 1` 的 draft（单帧不构成 session）

draft.id = firstFrame.id（Q4 锁定）

### 6.2 AssignmentResolver

```swift
public enum AssignmentResolver {
    public static func resolve(
        draft: ActivitySessionDraft,
        rules: [ProjectActivityRule],
        preserved: PreservedAssignment?,
        relatedFrames: [ActivityFrame]
    ) -> ResolvedActivitySession
}
```

算法：

1. 若 `preserved != nil`：直接采用 preserved 的 status/projectID，`assignmentSource = "manual"` —— **不**跑 rules
2. 若 preserved 为 nil：进入 rule 评估，`enabledRules = rules.filter { $0.isEnabled }`
3. 按 kind 优先级 `urlContains > titleContains > bundleIDEquals` 顺序遍历，每个 kind 内按 `createdAt asc` 排序
4. 命中条件（pattern 已 trim 但未 lowercase，匹配时按 kind 做 normalize）：
   - **urlContains**：遍历 `relatedFrames.compactMap { $0.browserURL }`，每个 normalize 为 `(host lowercase + 去 query/fragment)`；任意一个 `normalizedURL.contains(rule.pattern.lowercased())` 即命中
   - **titleContains**：遍历 `relatedFrames.compactMap { $0.windowTitle }`，每个 `TextSanitizer.stripInvisibleControls(_).lowercased()` 后；任意一个 `normalizedTitle.contains(rule.pattern.lowercased())` 即命中
   - **bundleIDEquals**：`draft.bundleID == rule.pattern`（**严格大小写敏感**，macOS bundle ID 大小写有效）
5. 首次命中即返回：`status = .ruleAssigned, projectID = rule.projectID, source = "rule:\(rule.id.uuidString)"`
6. 全不命中：`status = .unassigned, projectID = nil, source = nil`

### 6.3 ActivitySessionReconciler

```swift
public enum ActivitySessionReconciler {
    public static func replaceWindow(
        since: Date,
        until: Date,
        with resolved: [ResolvedActivitySession],
        in store: MemoryStore
    ) throws
}
```

步骤顺序（**critical** — 任何重排会破坏数据完整性）：

1. **先读 staleIds**：`let staleIds = try store.fetchActivitySessionIDs(since: since, until: until)` —— 必须早于 delete sessions
2. **删 sessions + join**：`try store.deleteActivitySessions(ids: staleIds)`（同时 cascade delete `activity_session_frames` 行 by application code）
3. **删 stale activitySession sources（双保险）**：
   - 路径 a：路径稳定 lookup → 按 id 删除
     ```swift
     for sid in staleIds {
         if let src = try store.findSourceByPath("activity-sessions/\(sid.uuidString)") {
             try store.deleteSource(id: src.id)
         }
     }
     ```
   - 路径 b（兜底孤儿）：`let orphans = try store.fetchActivitySessionSources(since: since, until: until); for src in orphans { try store.deleteSource(id: src.id) }`
4. **写新 sessions + join**：每个 resolved → `INSERT INTO activity_sessions...` + 每个 frameID → `INSERT INTO activity_session_frames...`
5. **Materialize eligible**：对每个 resolved，**当且仅当**满足三条同时：`assignmentStatus ∈ {.ruleAssigned, .manualAssigned} ∧ category == .work ∧ projectID != nil`：
   - `extractedText = makeExtractedText(resolved.draft)`，若 nil 跳过
   - 通过 `TextSanitizer.stripInvisibleControls(_:)`
   - `INSERT INTO memory_sources` with `path = "activity-sessions/\(draft.id.uuidString)"`, `kind = .activitySession`, `projectID = resolved.projectID!`（gate 已确保非 nil），...

### 6.4 SessionPipeline orchestration

```swift
@MainActor
internal final class SessionPipeline {
    func run(window: DateInterval) throws {
        let preserved = try store.fetchActivitySessionAssignments(
            since: window.start,
            until: window.end
        )
        // SQL: SELECT ... WHERE ended_at >= ? AND started_at <= ?
        //                  AND assignment_source = 'manual'
        //                  AND assignment_status IN ('manualAssigned', 'ignored')

        let preservedByID = Dictionary(
            uniqueKeysWithValues: preserved.map { ($0.sessionID, $0) }
        )

        let frames = try store.fetchActivityFrames(since: window.start, until: window.end)
        let framesByID = Dictionary(
            uniqueKeysWithValues: frames.map { ($0.id, $0) }
        )

        let drafts = SessionAggregator.aggregate(frames)
        let rules = try store.fetchRules()

        let resolved = drafts.map { draft -> ResolvedActivitySession in
            let related = draft.frameIDs.compactMap { framesByID[$0] }
            return AssignmentResolver.resolve(
                draft: draft,
                rules: rules,
                preserved: preservedByID[draft.id],
                relatedFrames: related
            )
        }

        try ActivitySessionReconciler.replaceWindow(
            since: window.start,
            until: window.end,
            with: resolved,
            in: store
        )
    }
}
```

### 6.5 makeExtractedText（隐私 gate）

```swift
internal func makeExtractedText(_ session: ActivitySessionDraft) -> String? {
    // gate: 只 work 进 prompt（assignment gate 在 reconciler 一层已经 filter；
    //        这里只保留 category gate 作为最后一道防线）
    guard session.category == .work else { return nil }

    var lines: [String] = []
    lines.append("应用：\(session.appName)")
    lines.append("时长：\(formatDuration(session.startedAt, session.endedAt))")
    lines.append("时间：\(formatTimeRange(session.startedAt, session.endedAt))")

    if let host = session.browserHost {
        // browser session: 仅 host，不含 titleSamples、不含 url path/query
        lines.append("网址：\(host)")
    } else {
        // non-browser work session: 可含 titleSamples
        let topTitles = session.titleSamples.prefix(3).map { String($0.prefix(120)) }
        if !topTitles.isEmpty {
            lines.append("窗口：")
            for t in topTitles { lines.append("  - \(t)") }
        }
    }

    let raw = lines.joined(separator: "\n")
    return TextSanitizer.stripInvisibleControls(raw)
}
```

`TextSanitizer.stripInvisibleControls(_:)` 是 Phase A 已有实现（位于 `Sources/ProjectMemoryCore/TextSanitizer.swift`，去 Cf/Cc 不可见 Unicode，保留 `\n` `\t`）。Phase 2 直接复用，不新增 wrapper。

## 7. Brief / Q&A 集成

### 7.1 SourceSnippetSelector 接口拆分（Phase 2 前置手术）

新类型：

```swift
public struct SelectedSourceSnippet: Equatable {
    public let source: MemorySource    // 原始 source，未截断
    public let snippet: String         // 发给 OpenRouter 的截断 + sanitize 后文本
    public let truncated: Bool
}

public struct ActivitySessionCaps: Equatable {
    public let maxSourcesPerBrief: Int        // 4
    public let maxSourcesPerAnswer: Int       // 2
    public let maxCharsPerSource: Int         // 400
    public let maxTotalBriefActivityChars: Int   // 900
    public let maxTotalAnswerActivityChars: Int  // 600

    public static let `default` = ActivitySessionCaps(
        maxSourcesPerBrief: 4,
        maxSourcesPerAnswer: 2,
        maxCharsPerSource: 400,
        maxTotalBriefActivityChars: 900,
        maxTotalAnswerActivityChars: 600
    )
}
```

新协议：

```swift
public protocol SourceSnippetSelecting {
    func selectForBrief(
        candidates: [MemorySource],
        caps: ActivitySessionCaps,
        now: Date
    ) -> [SelectedSourceSnippet]

    func selectForAnswer(
        candidates: [MemorySource],
        query: AnswerQuery,
        caps: ActivitySessionCaps
    ) -> [SelectedSourceSnippet]
}
```

`AnswerQuery` 新增字段 `selectedProjectID: UUID?`。

### 7.2 BriefGenerator / AnswerEngine 接口改造（hard）

- 接收 `[SelectedSourceSnippet]`，**不**再接收 `[MemorySource]`
- prompt 拼接路径只能读：
  - `SelectedSourceSnippet.snippet`
  - `SelectedSourceSnippet.source.title`
  - `SelectedSourceSnippet.source.path`
  - `SelectedSourceSnippet.source.url`
- **禁止**读 `SelectedSourceSnippet.source.extractedText`
- 内部 helper 也禁止读 `extractedText`
- 所有 SourceKind 走 SelectedSourceSnippet（不只是 activity）—— markdown / pdf / html / text / gitCommit / webCapture 全部统一接口

### 7.3 Selector 总额与 caps（完整算法）

**全局总额（既有，Phase 2 不改数字，仅显式写出）**：

```swift
public struct SelectionTotals {
    public let maxSourcesPerBrief: Int       // 12
    public let maxSourcesPerAnswer: Int      // 8
    public let maxSourcesPerProject: Int     // 3 — 单项目多样性 cap

    public static let `default` = SelectionTotals(
        maxSourcesPerBrief: 12,
        maxSourcesPerAnswer: 8,
        maxSourcesPerProject: 3
    )
}
```

**caps 语义（critical）**：所有 caps 都是**上限**，不是保底/配额。如果某 kind 候选不足，它不会"占满"分配位 —— 只是空着，腾给其他 kind。

**Brief selection 算法**（按顺序应用）：

```text
1. 按 kind 分桶：
   - activitySession bucket（已经经 §6.3 三重 gate，候选池只含 assigned + .work + projectID != nil）
   - 其他 SourceKind buckets

2. activitySession bucket：
   a. 按 modifiedAt desc 排序
   b. 取前 caps.maxSourcesPerBrief (= 4) 作为 kind cap
   c. 不参与 keyword scoring（结构化文本，词频失真）

3. 其他 buckets 走现有 selector 逻辑（recency-weighted），各自有现有的 kind cap

4. 合并所有 buckets 成单列，按 modifiedAt desc 重排

5. 应用 per-project cap：
   - 按 projectID 分组（projectID == nil 视为单独"无项目"组）
   - 每组保留前 totals.maxSourcesPerProject (= 3) 条，其余丢弃
   - **注意**：activitySession 必有 projectID（gate 保证），所以不会进"无项目"组

6. 应用全局总额 cap：
   - 按 modifiedAt desc 重新切到前 totals.maxSourcesPerBrief (= 12)

7. 对入选的每条 source 生成 SelectedSourceSnippet：
   - activitySession：snippet = sanitize(truncate(extractedText, caps.maxCharsPerSource = 400))；
     若截断，末尾附加「[内容已截断，仅发送相关片段]」并设 truncated = true
   - 其他 kinds：现有 snippet 截断逻辑（per-kind 字符上限），同样输出 SelectedSourceSnippet

8. 全局 activity 字数上限：
   - 累计 activitySession snippet 字符数 > caps.maxTotalBriefActivityChars (= 900) 时
     从尾部（最旧）开始丢弃 activitySession SelectedSourceSnippet 直到达标
   - 这一步不会影响其他 kind 的 SelectedSourceSnippet
```

**输出**：`[SelectedSourceSnippet]`，长度 ≤ 12，其中 activitySession 数量 ≤ 4，每 project 数量 ≤ 3。

### 7.4 Q&A selection 算法（hard，与 Brief 同骨架但 caps 不同）

**前置 hard rule**（与 §7.3 caps 算法独立，先于步骤 1）：

```text
Q&A only considers .activitySession sources whose projectID == query.selectedProjectID.
If query.selectedProjectID == nil, .activitySession sources are excluded entirely
(候选池在进入 selector 前就过滤掉，bucket 直接为空).
```

**算法**（与 §7.3 同骨架，仅换 caps）：

```text
1. 按 kind 分桶：
   - activitySession bucket：
       if query.selectedProjectID == nil: 空池
       else: candidates.filter { $0.kind == .activitySession && $0.projectID == query.selectedProjectID }
   - 其他 SourceKind buckets

2. activitySession bucket：
   a. 按 modifiedAt desc 排序（已是单 project，不需再过滤）
   b. 取前 caps.maxSourcesPerAnswer (= 2) 作为 kind cap
   c. 不参与 keyword scoring

3. 其他 buckets 走现有 Q&A selector 逻辑（keyword score-weighted），各自现有 kind cap

4. 合并 + per-project cap (= 3) + 全局总额 cap (= 8) 同 §7.3 步骤 4-6

5. SelectedSourceSnippet 生成同 §7.3 步骤 7

6. 全局 activity 字数上限：
   累计 activitySession snippet > caps.maxTotalAnswerActivityChars (= 600) 时
   从尾部丢弃 activitySession snippets 直到达标
```

**输出**：`[SelectedSourceSnippet]`，长度 ≤ 8，其中 activitySession 数量 ≤ 2 且必属同一 project（或 0 条），每 project 数量 ≤ 3。

### 7.5 caps & totals 速查表

| 维度 | Brief | Q&A |
|---|---|---|
| 全局总额 source 数 | 12 | 8 |
| activitySession kind cap | ≤ 4 | ≤ 2 |
| per-project source 数 | ≤ 3 | ≤ 3 |
| activitySession 单条字符上限 | 400 | 400 |
| activitySession 累计字符上限 | 900 | 600 |
| activitySession projectID 范围 | 任意 assigned project | 必须 == query.selectedProjectID |
| query.selectedProjectID == nil 时 activitySession | （N/A，brief 无此参数） | **完全排除** |

### 7.6 隐私边界总览（重锁）

| 阶段 | 数据所在 | 上 OpenRouter? |
|---|---|---|
| ActivityFrame raw | `activity_frames` | ❌ 永远不 |
| ActivitySession（任何状态） | `activity_sessions` | ❌ 不直接 |
| MemorySource(kind=.activitySession)，仅 `(.ruleAssigned ∨ .manualAssigned) ∧ .work ∧ projectID != nil` | `memory_sources` | ✅ 经 selector 截断为 snippet |
| MemorySource.extractedText 字段本体 | — | ❌ prompt 路径禁止读，仅通过 SelectedSourceSnippet.snippet |
| URL path / query | — | ❌ extractedText 仅含 host |
| Title samples（non-browser only） | — | ✅ 经 `TextSanitizer.stripInvisibleControls` + selector cap |
| unassigned / ignored / non-work / projectID==nil | — | ❌ 物理上无法 materialize → 不可能进 prompt |

## 8. Triage UI

### 8.1 Tab 布局

主导航新增 "待归属" tab，位置：

```
今日 | 项目 | 来源 | 待归属 | 提问 | 设置
```

icon: `questionmark.square`。badge：当前 `assignmentStatus == .unassigned ∧ category == .work` 的 session 数；超过 99 显示 `99+`。

### 8.2 列表视图

默认筛选：

```swift
struct TriageFilter {
    var status: AssignmentStatus = .unassigned
    var lookback: TimeInterval = 7 * 24 * 3600    // 7 天
    var showIgnored: Bool = false                  // 折叠区
}
```

按 `endedAt desc` 排序。空态："暂无待归属的工作时段。"

每行卡片显示：

- 时间范围 + 时长 + 帧数
- 应用名（大）+ bundleID（小）
- 浏览器 host（仅 host，不含 path/query）
- titleSamples 前 3 条，每条 80 chars
- 操作按钮：`[归属到项目 ▼]` `[忽略]`

折叠区"已忽略"：每行只有一个"撤销忽略"按钮。

### 8.3 操作

仅三个：

- `.assign(projectID)` —— 归属到现有 / 新建项目
- `.ignore` —— 忽略
- `.undoIgnore` —— 撤销忽略

不允许：手动改 category、edit session 字段、从 triage 创建/编辑 rules（rules 编辑统一在设置页）。

### 8.4 操作流（与 §6.4 pipeline 一致）

```text
1. App 层 triageAction(sessionID, action)
2. fetch session by id 拿 startedAt / endedAt
3. store.updateActivitySessionAssignment(
     sessionID,
     assignmentStatus: <见下>,
     projectID: <见下>,
     assignmentSource: <见下>
   )                                              ← 必须 commit 后再进 step 4
4. pipeline.run(window: [session.startedAt, session.endedAt])
5. pipeline.run 第一步: fetchActivitySessionAssignments(window)
   ← 必须读到 step 3 写入的 manual row（否则会被 reconciler 覆盖）
6. preserved map 命中 → resolver 跳过 rules，直接采用 manual 决策
7. reconciler.replaceWindow → 更新 sessions 与 sources
8. UI listener 收到 store change → 列表刷新
```

step 3 字段写入规则：

| Action | assignmentStatus | projectID | assignmentSource |
|---|---|---|---|
| `.assign(projectID)` | `.manualAssigned` | `projectID` | `"manual"` |
| `.ignore` | `.ignored` | `nil` | `"manual"` |
| `.undoIgnore` | `.unassigned` | `nil` | `nil` |

### 8.5 Manual 持久性矩阵

| 场景 | 期望 | 机制 |
|---|---|---|
| Manual assign → 重启 app | 保留 | activity_sessions 行持久化 |
| Manual assign → rule 改了（同 session 命中新规则） | manual 保留 | preserved map 优先于 resolver |
| Manual assign → 新 frame 延长 endedAt | session.id 不变（firstFrame.id），manual 保留 | preserved map 命中 |
| Ignored → rule 后来命中 | ignored 保留 | preserved map 优先 |
| Ignored → 用户撤销忽略 | status=.unassigned, source=nil；下次 pipeline 走 rule 路径 | 不在 preserved map → resolver |
| 同 session 先 ignore 后 assign | manualAssigned 覆盖 | activity_sessions 行单行 update |
| unassigned → rule 命中 | rule 接管，status=.ruleAssigned, source="rule:<uuid>" | 不在 preserved map（source != "manual"），resolver 重新评估 |

### 8.6 边界 case

- **Window 由被操作 session 决定**：`pipeline.run(window: [session.startedAt, session.endedAt])`，不是 `pipeline.run(window: lastNHours)`
- **UI debounce**：100ms 内多次 triage actions 合并成一次 pipeline.run，window = union 各 session 窗口
- **App 自身 frontmost 时**：coordinator self-pause 生效（Phase 1），不会因 triage 操作产生新的 unassigned session

## 9. Testing strategy

### 9.1 纯函数单元测试（Core，无 I/O）

**SessionAggregator**：空输入、单 frame 丢弃、同 identity < 5min 同 session、> 5min 切 session、不同 identity 切 session、非浏览器仅看 bundleID、乱序输入、`session.id == firstFrame.id`、titleSamples（max 5、first-seen 顺序、sanitize + trim 后去重、空串跳过）、frameCount 准确。

**AssignmentResolver**：preserved 命中跳过 rules、kind 优先级 `urlContains > titleContains > bundleIDEquals`、同 kind 内 createdAt asc 首次命中、urlContains 扫所有 relatedFrames（normalize 后 contains）、titleContains 扫所有 windowTitles、bundleIDEquals 严格相等、disabled rule 跳过、空 rules 输入返回 unassigned。

### 9.2 集成测试（in-memory MemoryStore）

**ActivitySessionReconciler.replaceWindow**：

- 步骤顺序（先读 staleIds 再 delete）—— 构造旧 session A 对应 source path = `"activity-sessions/A"`，replaceWindow 后断言旧 source 已删
- 双保险孤儿清理 —— 构造 source 行存在但 session 行已被早期 bug 删掉的状态，断言 reconciler 仍然清掉 source
- Materialization gate（三条同时）—— `.unassigned + .work + project != nil` 不 materialize（status fail）；`.manualAssigned + .socialMedia + project != nil` 不 materialize（category fail）；`.manualAssigned + .work + projectID == nil` 不 materialize（projectID fail）；只有三条全满足 `(manualAssigned ∨ ruleAssigned) ∧ .work ∧ projectID != nil` 才 materialize

**SessionPipeline.run**：

- preserved 优先：构造 manual session A 命中某 rule，run 后 A 仍然 source="manual"
- ignored session 不被 rule 重新接管
- undoIgnore（.unassigned, source=nil）→ run 后 rule 重新评估
- idempotent：threshold 不变下重 run 同窗口，session ids 与 manual 决策不变

### 9.3 Mechanical privacy guards（load-bearing 源码扫描）

**这是 Phase 2 最关键的一组测试** —— 任何后续重构如果绕过 SelectedSourceSnippet 直接读 DB 字段，CI 立刻挂。

```swift
final class PromptPathPrivacyGuardsTests: XCTestCase {
    // === BriefGenerator ===
    func testBriefGeneratorDoesNotReferenceActivityFrame()
    func testBriefGeneratorDoesNotReferenceActivityFramesTable()
    func testBriefGeneratorDoesNotReadExtractedTextDirectly()

    // === AnswerEngine ===
    func testAnswerEngineDoesNotReferenceActivityFrame()
    func testAnswerEngineDoesNotReferenceActivityFramesTable()
    func testAnswerEngineDoesNotReadExtractedTextDirectly()

    // === Prompt helpers (any PromptBuilder*.swift) ===
    func testPromptHelpersDoNotReadExtractedText()

    // === SourceSnippetSelector ===
    // 允许 .extractedText（它就是干这事的），但禁止访问 ActivityFrame / activity_frames
    func testSelectorDoesNotTouchActivityFrames()
}
```

**白名单**：扫描 `.extractedText` 仅覆盖 BriefGenerator / AnswerEngine / Prompt helpers，**不**覆盖 SourceSnippetSelector（它合法读 extractedText 生成 snippet）。

实现：用 `Bundle.module` 或工程相对路径读取 `.swift` 文件 raw bytes 进行 substring 匹配。Phase 1 已有 BriefGenerator / AnswerEngine 的 `ActivityFrame` 扫描，Phase 2 扩展到 `.extractedText` + 增加 prompt helper 文件。

### 9.4 运行时隐私 sentinel 测试

**精确证明 prompt 路径不绕过 snippet**：

BriefGenerator / AnswerEngine 的职责是**生成 prompt string**，**不**负责调用 OpenRouter（OpenRouterClient 是独立组件）。所以 sentinel 测试应该直接调 BriefGenerator 拿到返回的 prompt string，不 mock 任何网络层。

```swift
func testBriefPromptOnlyReadsSnippetNotSourceExtractedText() {
    let leak = "LEAK_SENTINEL_\(UUID().uuidString)"
    let safe = "SAFE_SNIPPET_\(UUID().uuidString)"
    let src = MemorySource(... extractedText: leak ...)
    let snippet = SelectedSourceSnippet(source: src, snippet: safe, truncated: false)

    let prompt: String = BriefGenerator.buildPrompt(snippets: [snippet], ...)

    XCTAssertTrue(prompt.contains(safe))
    XCTAssertFalse(prompt.contains(leak))
}

func testAnswerPromptNeverContainsActivityFromOtherProject() {
    // projectA / projectB 各有一个 activitySession source
    // query.selectedProjectID = projectA.id
    // 直接调 AnswerEngine.buildPrompt，断言 prompt 不含 projectB session 的任何
    // title sample / host —— 不 mock 任何 OpenRouter 调用
}

func testAnswerPromptNoActivityWhenNoProjectSelected() {
    // query.selectedProjectID = nil → AnswerEngine.buildPrompt 输出不含 activitySession 段
}

func testUnassignedSessionsNeverInPrompt() {
    // session A status=.unassigned, B=.ignored, C=.ruleAssigned, D=.manualAssigned
    // 断言：A、B 不产生 MemorySource → selector 候选池不含 → prompt 不含
    // Phase 2 隐私边界的最终防线
}
```

### 9.5 Caps 边界测试

```swift
func testBriefCaps() {
    // 10 个 activitySession sources（assigned + .work）
    // 断言：selector 输出 ≤ 4 个 SelectedSourceSnippet for activity
    // 每个 snippet.length ≤ 400
    // 累计 ≤ 900
    // 截断的 snippet truncated == true 且 snippet 末尾含「[内容已截断，仅发送相关片段]」
}

func testAnswerCaps() {
    // 同理 ≤ 2 / ≤ 400 / ≤ 600
}

func testCapsNotAppliedToNonActivity() {
    // markdown source 走现有 selector 逻辑，不被 activity caps 影响
    // 但同样产出 SelectedSourceSnippet
}
```

### 9.6 Triage 持久性测试

把 §8.5 持久性矩阵的正向断言落地（**不**写 gap threshold breaking 这一条 —— 仅作 docs known limitation）：

```swift
func testManualAssignSurvivesRestart()
func testManualAssignSurvivesRuleChange()
func testManualAssignSurvivesEndedAtExtension()
func testIgnoredSurvivesRuleMatch()
func testUndoIgnoreReevaluatesRules()
func testIgnoreThenAssignOverwrites()
func testRuleAssignmentReevaluatedOnRuleChange()
```

### 9.7 UI smoke（lightweight）

ViewModel-level 测试（与 Phase 1 一致，UI 视觉走人工 smoke）：

- TriageListViewModel 默认筛选只看 unassigned + .work
- Badge count 与 store 同步
- triageAction 调用 pipeline.run window 是 session.startedAt..endedAt（不是 user clock）

### 9.8 Coverage gate

每次实施任务后：

- `swift build` clean，0 deprecated warnings
- `swift test` 全绿
- §9.3 mechanical guards 全绿（load-bearing）
- §9.4 sentinel test 全绿（load-bearing）
- 新加测试与改动的代码同 PR / 同提交

预期：Phase 1 的 108 测试基础上增加约 40-50 个，落地后约 150 上下。**目标不是数量，是 §9.3 + §9.4 是绿色 = 隐私边界没破**。

## 10. Known limitations

写进 docs，**不**编码进必失败测试：

- **修改 `sessionGapThreshold` (5min) 是 breaking config change**：会改变 session 切分边界 → first frame 落点 → session.id 漂移 → 旧 manual assignments 失效。Phase 2 不计划改这个阈值；如未来需要修改，应同时设计 fuzzy preservation 机制（Phase 3 backlog）。
- **首帧 frame 删除 = session.id 失效**：Phase 1 的 30 天 retention 删除 frame 时不会单独删除一个 frame —— 整批按时间窗清理；但如果未来引入"删某个 frame"操作，会破坏 session.id 的 firstFrame 锁定。retention 操作必须以 session 为单位整段删，不允许残留 frame。
- **同 bundleID + 不同 host 切 session**：浏览器在两个 tab 间快速切换会被切成多个 session（每 host 一段），即使用户主观感觉是连续工作。Phase 2 不做"merge across host"。

## 11. Phase 2.5 backlog

记录但 Phase 2 不做：

- 从 Triage UI 一键创建规则（"为这类 session 自动归属")
- Rule 编辑 UI 的 preview（命中数量、命中样本）
- Activity timeline 可视化（按项目分色、按 category 分行）
- Per-project session digest（"过去 7 天在 project X 上花了多少时间，主要在哪些 host"）
- Phase 1.5: optional OCR lane（独立 env flag + 用户 allowlist）

## 12. Acceptance criteria

Phase 2 ship 时必须同时满足：

1. `swift build` clean，0 deprecated warnings
2. `swift test` 全绿，§9.3 + §9.4 mechanical guards 与 sentinel 测试全绿
3. Phase 1 已有的 mechanical guards 不退化
4. 实际 dogfood 验证：
   - 至少一个 manual assign 能在重启后保留
   - 至少一条 rule 能正确归属 session 且 source = "rule:<uuid>"
   - Q&A 在选定项目下能引用到 activity session snippet
   - dogfood 时主动构造一个 ≥ 800 字的长 activity session（拼接长 titleSamples 触发截断），验证 snippet 末尾出现「[内容已截断，仅发送相关片段]」标记 —— 短 session 不必带标记
   - 切到无项目 query → 不出现 activitySession 段
   - 待归属 tab badge 与列表数量一致
5. Privacy review 通过：
   - prompt 不出现 activity_frames / ActivityFrame 引用（源码扫描）
   - prompt 不直接读 source.extractedText（源码扫描 + sentinel runtime）
   - unassigned/ignored session 物理上不进 prompt（runtime test）

---

**Spec end. 等 user review。**
