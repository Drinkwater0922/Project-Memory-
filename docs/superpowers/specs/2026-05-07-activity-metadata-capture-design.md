# Activity Metadata Capture — Design Spec

日期：2026-05-07
作者：Claude（研发 SE + 评测工程师）+ codex（工程 review）+ user（产品决策）
状态：等 user spec review

## 1. 问题与目标

**问题**：用户提出把"屏幕快照"扩展成 Rewind 风格的全局记忆，能跨"工作 / 刷社媒 / 聊天"等类别分析活动。

**目标（本 spec 限定 Phase 1）**：在 Project Memory 现有产品基础上，新增一条**纯元数据**的活动捕获管道，记录用户在哪个 app / 看哪个 URL / 大致花了多少时间，按 app + URL host 自动打活动类别标签。Phase 1 数据 **不** 进入 brief / Q&A / OpenRouter，仅落本地 SQLite，为 Phase 2（session 聚合 + 项目归属 + brief 整合）准备底料。

**为什么这样切**：
- 维持 Project Memory "项目状态恢复"主线（Q1 决策：扩张 not 替代）
- 保留 Phase A 已经做出的"丢截图"决策的隐私叙事一致性
- 把高敏感的截图 / OCR 路径推到独立 Phase 1.5 + opt-in 模型，不污染 Phase 1
- Phase 1 ship 后即使 dogfood 不接 brief，也能观察真实数据形态

## 2. 非目标

Phase 1 **不**做以下任何一项（写明避免漂移）：

- 截图：无 ScreenCaptureKit、无 `CGWindowListCreateImage`、无图像字节落盘
- OCR：无 Vision、无 NaturalLanguage、无任何视觉文字提取
- Brief / Q&A / OpenRouter 接入：activity 数据**不**经过 `SourceSnippetSelector`、**不**进 `BriefGenerator`、**不**经 `OpenRouterClient`
- 项目归属：`ActivityFrame.projectID` 字段存在但 Phase 1 始终 nil；triage UI 在 Phase 2
- Session 聚合：连续帧合并成 `MemorySource(.activitySession)` 是 Phase 2 工作
- Tier 2（capture-but-local-only）：Phase 3 才考虑
- LLM-based 分类：Phase 1 仅 bundleID + URL host 规则（避免把每帧 metadata 发外部模型）
- 用户可配 retention：Phase 1 硬编码 30 天
- 启用 SQLite `PRAGMA foreign_keys=ON`：独立工作

## 3. Decision Log（关键 fork）

七个产品 / 架构 fork 已对齐：

| # | 问题 | 决定 |
|---|---|---|
| Q1 | 与现有 Project Memory 关系 | **扩张** — 全局 capture 是新增 ingestion source，项目仍是主线 |
| Q2 | 项目 vs 活动类别关系 | **正交两维** — 每帧带 category + 可选 projectID |
| Q3 | 类别打标机制 | **bundleID + URL host 规则** — 不依赖 OCR / LLM |
| Q4 | 像素 / OCR 是否落盘 | **Phase 1: metadata only**（无截图、无 OCR）；**Phase 1.5: optional OCR lane**（独立 env flag + 用户 allowlist） |
| Q5 | Capture cadence | **混合** — 事件驱动 + 60s 心跳 + idle/lock/self pause |
| Q6 | 帧 / MemorySource 关系 | **帧 + Session 聚合两表** — 帧进 `activity_frames`；Phase 2 才聚合成 MemorySource |
| Q7 | 默认捕获 + deny-list | **单层 deny-list** — 6 个高置信默认 + 用户可加，URL deny-list 复用 |

## 4. 架构

```
┌─────────────────────────────────────────────────────────────────────┐
│  ActivityCoordinator  (ProjectMemoryApp, @MainActor)                 │
│  ─────                                                              │
│  - listens NSWorkspace.didActivateApplicationNotification           │
│  - listens screensDidSleepNotification + com.apple.screenIsLocked   │
│  - injected ActivityTickScheduler (60s heartbeat)                   │
│  - per-tick guard: idle≥5min / locked / self-frontmost → return     │
│  - per-tick: collector → gate → classifier → store                  │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  ActivityCandidateCollector  (ProjectMemoryApp, 全副作用集中)        │
│  ─────                                                              │
│  - NSWorkspace.frontmostApplication → bundleID, appName             │
│  - if bundleID ∈ supported browsers:                                │
│      BrowserTabReader.readActiveTab(bundleID:) → (title, url)        │
│        success → windowTitle=title, browserURL=url                  │
│        failure → windowTitle=nil, browserURL=nil                    │
│        (浏览器场景下两者绑定：URL 不可信时，title 也不可信)          │
│  - else (non-browser): NSAccessibility AX → windowTitle (best-effort)│
│  - 所有 string 字段在此层 sanitize via TextSanitizer                │
│  - 输出 ActivityCandidate(observedAt, bundleID, appName,            │
│           windowTitle?, browserURL?)  // 已 sanitized                │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  ActivityGate.decide(candidate, now, lastCaptureAt, extraDenied)    │
│  (ProjectMemoryCore, 纯函数)                                         │
│  ─────                                                              │
│  - ActivityDenyList.isDenied(bundleID, extraDenied) → skip          │
│  - browserURL != nil → URLDenyList.isDenied(url) → skip             │
│  - now - lastCaptureAt < 5s → skip (rate limit)                     │
│  - else → capture                                                   │
│  - 输出 Decision { capture: Bool, skipReason: String? }             │
└─────────────────────────────────────────────────────────────────────┘
                              │ capture=true
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  ActivityClassifier.classify(candidate)                             │
│  (ProjectMemoryCore, 纯函数)                                         │
│  ─────                                                              │
│  优先级（高→低）：                                                    │
│  1. bundleID ∈ chat/social/work 专用规则 → 对应 category             │
│  2. bundleID ∈ supported browsers + browserURL host                 │
│     命中 chat/social/work host 规则 → 对应 category                  │
│  3. browser + 未命中 / 无 URL → .other                                │
│  4. 都未命中 → .other                                                │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│  MemoryStore.saveActivityFrame(frame)                                │
│  (ProjectMemoryCore)                                                 │
│  ─────                                                              │
│  - 新表 activity_frames                                              │
│  - 纯持久化，**不做** sanitize / 校验 / 派生（caller 已处理）         │
│  - **不**出 MemorySource、**不**进 brief、**不**进 OpenRouter        │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.1 边界纪律

| Layer | Target | 内容 |
|---|---|---|
| 副作用 | App | Coordinator, CandidateCollector, BrowserTabReader, AutomationAttemptLog, RetentionGC, providers (idle/lock/frontmost) |
| 纯函数 | Core | ActivityGate, ActivityClassifier, ActivityDenyList, URLDenyList, TextSanitizer |
| 持久化 | Core | MemoryStore.activity_frames 接口 |
| Brief / Q&A | Core | **不感知 activity_frames**，Phase 2 才接 |

Provider protocols（`IdleStateProvider`、`ScreenLockStateProvider`、`FrontmostAppProvider`）只在 App target，Core 不需要 macOS 运行态概念。

## 5. 数据模型

### 5.1 Core 类型扩展（`Sources/ProjectMemoryCore/Models.swift` 追加）

```swift
public enum ActivityCategory: String, Codable, CaseIterable {
    case work
    case socialMedia
    case chat
    case other
}

public struct ActivityCandidate: Equatable {
    public let observedAt: Date
    public let bundleID: String
    public let appName: String
    public let windowTitle: String?    // best-effort, may be nil
    public let browserURL: String?     // 仅当 bundleID ∈ supported browsers
}

public struct ActivityFrame: Identifiable, Equatable, Codable {
    public let id: UUID
    public let observedAt: Date
    public let bundleID: String
    public let appName: String
    public let windowTitle: String?    // 已由 collector sanitize；浏览器场景：仅当 URL 读取成功时填充
    public let browserURL: String?     // 已由 collector sanitize；URLDenyList 在 Gate 拦截，到此处必 pass
    public let category: ActivityCategory
    public let projectID: UUID?        // Phase 1 始终 nil；Phase 2 设
    // Phase 1 故意不放 ocrText 字段；Phase 1.5 走独立表
}

public enum ProjectFilter: Equatable {
    case any
    case unassigned
    case project(UUID)
}
```

### 5.2 SQLite Schema

`MemoryStore.createSchema()` 追加：

```sql
CREATE TABLE IF NOT EXISTS activity_frames (
    id TEXT PRIMARY KEY,
    observed_at TEXT NOT NULL,            -- ISO 8601
    bundle_id TEXT NOT NULL,
    app_name TEXT NOT NULL,
    window_title TEXT,                    -- nullable; caller pre-sanitizes
    browser_url TEXT,                     -- nullable; caller pre-sanitizes & pre-deny-checks
    category TEXT NOT NULL,
    project_id TEXT REFERENCES projects(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS idx_activity_frames_observed_at
    ON activity_frames(observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_frames_category_observed
    ON activity_frames(category, observed_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_frames_project_observed
    ON activity_frames(project_id, observed_at DESC);
```

**FK 强制说明**：`SQLiteDatabase.init` 当前未启用 `PRAGMA foreign_keys=ON`，sources / timeline_events / briefs 三表的隐含 FK 也都没启用。本 spec 仅声明 `REFERENCES projects(id) ON DELETE SET NULL` 表达关系，**不**启用强制 — 启用是独立的破坏性变更（要审、要数据 sanity check、要回归全测试）。

### 5.3 Phase 1.5 OCR 表（仅占位，本 spec 不实施）

```sql
-- Phase 1.5 才创建
CREATE TABLE IF NOT EXISTS activity_frame_ocr (
    frame_id TEXT PRIMARY KEY REFERENCES activity_frames(id) ON DELETE CASCADE,
    ocr_text TEXT NOT NULL,
    created_at TEXT NOT NULL
);
```

OCR 单独表的好处：retention / 加密 / allowlist gating 都可独立做，不影响 metadata 主表。

### 5.4 MemoryStore 新增 API

```swift
public func saveActivityFrame(_ frame: ActivityFrame) throws

public func fetchActivityFrames(
    category: ActivityCategory? = nil,
    project: ProjectFilter = .any,
    since: Date? = nil,
    until: Date? = nil,
    limit: Int? = nil
) throws -> [ActivityFrame]

public func countActivityFrames(
    category: ActivityCategory? = nil,
    project: ProjectFilter = .any,
    since: Date? = nil,
    until: Date? = nil
) throws -> Int

public func deleteActivityFrames(beforeDate: Date) throws
```

`countActivityFrames` 与 `fetchActivityFrames` 过滤参数对齐，避免后续 dashboard 重复实现。

**Filter / boundary 语义**（实施时严格按此）：
- 默认排序：`observed_at DESC`
- `since`：取 `observed_at >= since`（左闭）
- `until`：取 `observed_at < until`（右开，方便分页 / 时间窗对齐）
- `limit`：在 ORDER BY 之后应用
- `deleteActivityFrames(beforeDate:)`：删 `observed_at < beforeDate`（与 `until` 一致的右开语义）
- 写入侧：`saveActivityFrame` 不做 sanitize / 校验 / 派生（caller 责任）— 单纯 INSERT OR REPLACE BY id

### 5.5 已有代码迁移

`AutoWebCaptureDenyList`（App target）→ `URLDenyList`（Core target）：

| 旧 | 新 |
|---|---|
| `Sources/ProjectMemoryApp/AutoWebCaptureDenyList.swift` | `Sources/ProjectMemoryCore/URLDenyList.swift` |
| `enum AutoWebCaptureDenyList` | `public enum URLDenyList` |
| 全局函数 `normalizeURLForDedup(_:)` | 静态方法 `URLDenyList.normalizeForDedup(_:)` |
| `AutoWebCaptureTests.testDenyList...` | `URLDenyListTests`（移到 Core test target） |
| `AutoWebCaptureTests.testNormalize...` | `URLDenyListTests`（移到 Core test target） |
| `AutoWebCaptureTests.testSupportedBrowser...` | 留在 `AutoWebCaptureTests`（App-only） |

`AppState.persistAutoWebCapture` callsite 跟随更新。

### 5.6 ActivityDenyList — 高置信默认

```swift
public enum ActivityDenyList {
    public static let defaultBundleIDs: Set<String> = [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword4",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.keychainaccess"
    ]

    public static func isDenied(bundleID: String, extraDenied: Set<String> = []) -> Bool {
        defaultBundleIDs.contains(bundleID) || extraDenied.contains(bundleID)
    }
}
```

不放低置信银行 / 医疗 / 公司内部 app — false security 比 false negative 更糟。用户在 Settings 加 `extraDenied`。

ProjectMemoryApp 自身**不**进 deny-list — 由 Coordinator hard pause（§6.3）。

### 5.7 Skip 不持久化

仅 `decision.capture == true` 写一行 `activity_frames`。被 deny / idle / 自身前台 / rate-limit 拦下的 → 不写表。可观测性靠 Coordinator 内存计数器（不持久化），如未来要"我多少时间花在 deny-list app 上"再加聚合表。

## 6. 隐私 / 权限 / 生命周期

### 6.1 Hard gate vs Capability gate

**Hard gates**（任一 false → Coordinator 完全不 tick）：

| 层 | 机制 | 默认 |
|---|---|---|
| Runtime dev flag | `PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1` 进程环境变量（Xcode scheme env 或 shell `VAR=val swift run`） | **off** |
| User toggle | Settings 里"活动记录"toggle，状态写 `UserDefaults` | **off** |

**Capability gates**（不影响是否 capture，只影响 frame 字段是否填）：

| Capability | 适用场景 | 失败行为 |
|---|---|---|
| Accessibility (AX) | 非 browser app 的 windowTitle | 仍写 frame，`windowTitle = nil` |
| Automation per browser | supported browser 的 URL + tab title | 仍写 frame，`browserURL = nil` **且** `windowTitle = nil`（绑定：URL 不可信时 title 也不可信） |
| Screen Recording | Phase 1 不需要 | — |

**为什么浏览器下 windowTitle 和 browserURL 绑定**：浏览器 window title 通常等于页面 title（例如 "Bank of America - Online Banking"）。如果 URL 读取失败（Automation 拒绝 / 无 active tab），我们没法跑 URL deny-list 验证页面安全；此时保留 title 等于无 deny-list 保护就把页面信息写进库。Fail-safe 的做法是 URL 不可信时同时清掉 title。

### 6.2 macOS 权限矩阵（Phase 1）

| Capability | 何时需要 | 何时检查 |
|---|---|---|
| Frontmost app + bundleID + appName | 总是 | 无权限要求 |
| windowTitle | capture 时 | 启动时 `AXIsProcessTrusted()`，未授权 → Settings 状态行提示 |
| browserURL | frontmost ∈ supported browsers 时 | 首次 osascript 调用时系统弹 Automation 框；失败 → 仅 metadata 不带 URL |

### 6.3 Pause guards（Coordinator tick 入口）

```swift
guard envFlagOn else { return }
guard userToggleOn else { return }
guard !idleStateProvider.secondsSinceLastUserInput().isAtLeast(300) else { return }
guard !screenLockStateProvider.isScreenLocked else { return }
guard frontmostAppProvider.frontmostBundleID != selfBundleID else { return }
```

`selfBundleID = Bundle.main.bundleIdentifier ?? "ProjectMemoryApp"`，构造时记一次，硬编码 pause；不通过 Settings、不通过 Gate（Gate 看不到运行态信息）。

### 6.4 Idle / Lock / Frontmost provider protocols

仅在 App target：

```swift
internal protocol IdleStateProvider {
    func secondsSinceLastUserInput() -> TimeInterval
}
internal protocol ScreenLockStateProvider {
    var isScreenLocked: Bool { get }
}
internal protocol FrontmostAppProvider {
    var frontmostBundleID: String? { get }
}
```

真实实现：
- `IdleStateProvider`：`CGEventSource.secondsSinceLastEventType`（具体 raw value 由实现决定，**spec 不锁死**）
- `ScreenLockStateProvider`：`CGSessionCopyCurrentDictionary` 读 `kCGSSessionScreenIsLocked`，外加监听 `screensDidSleepNotification` + `com.apple.screenIsLocked` 缓存最新值
- `FrontmostAppProvider`：`NSWorkspace.shared.frontmostApplication?.bundleIdentifier`

### 6.5 Automation 状态 — last-attempt 模型

`AutomationAttemptLog` 持久化每个 browser bundleID 的最近一次结果到 UserDefaults：

```swift
internal enum AutomationOutcome: Codable {
    case success(at: Date)
    case failure(at: Date, reason: String)
    case notAttempted
}
```

`BrowserTabReader` 实现里每次调用 osascript 后 update。Settings UI 读取展示，不承诺实时系统级状态：

```
Automation
  Safari   上次：成功 (2026-05-07 14:32)
  Chrome   上次：失败 — 用户拒绝授权 (2026-05-07 13:10)
  Arc      尚未尝试
首次读取浏览器 URL 时 macOS 会弹授权提示。
```

### 6.6 BrowserTabReader 抽象（共享）

```swift
internal protocol BrowserTabReader {
    func readActiveTab(bundleID: String) throws -> (title: String, url: String)
}

internal final class OSABrowserTabReader: BrowserTabReader {
    private let attemptLog: AutomationAttemptLog
    init(attemptLog: AutomationAttemptLog) { ... }
    func readActiveTab(bundleID: String) throws -> (title: String, url: String) {
        // osascript 逻辑（从 AutoWebCaptureService.activeTab 搬来）
        // 成功 / 失败都写 attemptLog
    }
}
```

迁移：
- `AutoWebCaptureService` 持有一个 `BrowserTabReader`，通过它取 URL+title。`captureActiveBrowser()` 仍负责"判断 frontmost 是不是 supported browser + 包成 `AutoWebCaptureResult`"
- `ActivityCandidateCollector` 也注入同一个 `BrowserTabReader`，browser 路径直接调它
- `AutomationAttemptLog` 由 `BrowserTabReader` 单点更新，避免双源

### 6.7 Settings UI（Phase 1 最小化）

新 section "活动记录"：

```
┌─ 活动记录 ─────────────────────────────────────┐
│ □ 启用活动元数据记录                              │
│   仅记录前台 app / 窗口标题（如有 AX 权限）/      │
│   浏览器 URL（如有 Automation 权限）。            │
│   不截图、不 OCR、不发送到 OpenRouter。           │
│                                                 │
│ 排除的应用                                       │
│   默认 (不可删)                                  │
│   • 1Password / Bitwarden / KeePassXC /         │
│     Keychain Access ...                          │
│                                                 │
│   自定义                                         │
│   • [com.example.private]   [-]                 │
│   ─────────────                                  │
│   [添加 bundle ID    ] [+]                       │
│                                                 │
│ 权限状态                                          │
│   Accessibility ✓ 已授权                         │
│   Automation                                     │
│     Safari   上次：成功 (2026-05-07 14:32)       │
│     Chrome   尚未尝试                             │
│                                                 │
│ Phase 1 调试                                     │
│   今日捕获：12 帧                                 │
│   最近一帧：Slack — chat — 14:32:05              │
│   [刷新]                                         │
│                                                 │
│ [清除所有活动记录]  (destructive, 二次确认)       │
└─────────────────────────────────────────────────┘
```

env flag off 时：toggle 显示 disabled 状态 + "Set `PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1` to enable" 提示。

### 6.8 extraDenied 输入校验

```swift
func tryAddExtraDeniedBundleID(_ input: String) -> AddResult {
    let cleaned = TextSanitizer.stripInvisibleControls(input)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return .rejectedEmpty }
    guard !ActivityDenyList.defaultBundleIDs.contains(cleaned)
        else { return .rejectedAlreadyInDefaults }
    var current = currentExtraDenied()
    guard !current.contains(cleaned) else { return .rejectedDuplicate }
    current.append(cleaned)
    persistExtraDenied(current)
    return .added(cleaned)
}
```

不做 reverse-DNS 格式校验 — dev / sideload app 可能不规范，硬验会误伤。

UserDefaults keys：
- `ProjectMemory.activityCaptureEnabled` (Bool)
- `ProjectMemory.activityExtraDeniedBundleIDs` ([String])
- `ProjectMemory.automationAttemptLog` (Data, JSON 编码 `[String: AutomationOutcome]`)

### 6.9 Coordinator 实时 start/stop

```swift
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var activityCaptureEnabled: Bool
    @Published private(set) var activityExtraDenied: [String]
    private var activityCoordinator: ActivityCoordinator?

    func setActivityCaptureEnabled(_ enabled: Bool) {
        activityCaptureEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.activityToggleKey)
        syncActivityCoordinator()
    }

    private func syncActivityCoordinator() {
        let shouldRun = Self.isActivityFeatureEnvOn && activityCaptureEnabled
        switch (shouldRun, activityCoordinator) {
        case (true, nil):
            let c = ActivityCoordinator(...)
            c.start()
            activityCoordinator = c
        case (false, .some(let c)):
            c.stop()
            activityCoordinator = nil
        default:
            break
        }
    }
}
```

Toggle 翻转立即生效，不需重启 app。

### 6.10 Retention / GC

```swift
public enum ActivityRetention {
    public static let defaultDays = 30
}
```

GC 触发：
- App 启动后 5 秒（错开 init 高峰）
- 此后每 24 小时一次（in-app timer，可注入 `ActivityTickScheduler` 测）
- 操作：`MemoryStore.deleteActivityFrames(beforeDate: Date().addingTimeInterval(-30*86400))`

Phase 1 不暴露用户配置；30 天是保守起点。

### 6.11 Phase 2 placeholder（不实施）

```swift
public func assignActivityFrames(ids: [UUID], to projectID: UUID?) throws
public func unassignActivityFrames(ids: [UUID]) throws  // = assign(to: nil)
```

Phase 2 triage UI 调用，把 `.unassigned` 帧批量归项目。

### 6.12 Phase 1.5 placeholder（不实施）

OCR lane 启用要：
- 独立 env flag `PROJECT_MEMORY_ENABLE_OCR_LANE=1`
- 用户在 Settings 显式 opt-in 一组 bundleID 进 "OCR allowlist"（**not** deny-list — 默认空）
- macOS Screen Recording 权限流（onboarding dialog）
- 新表 `activity_frame_ocr`（§5.3）+ `MemoryStore.upsertActivityFrameOCR(frameID:, text:)`
- 新组件 `ScreenshotProvider`（ScreenCaptureKit）+ `OCRService`（Vision）
- OCR 文本仍**不**进 brief / OpenRouter（边界由 Phase 2 SessionAggregator 决定）

## 7. Phase 切分 + Phase 1 实施 scope

### 7.1 路线图

| Phase | 内容 | OCR | 进 brief / OpenRouter |
|---|---|---|---|
| **1** | Activity Metadata Capture（本 spec 实施） | ❌ | ❌ |
| **1.5** | OCR Lane opt-in，独立 env flag + allowlist | ✅ 本地 | ❌ |
| **2** | Session 聚合 + 项目归属 + Brief 整合 | — | ✅（带 sanitization + selector） |
| **3+** | Tier 2、LLM 自动归属、可配 retention 等 | — | — |

每档独立可 ship、独立可 dogfood。Phase 2 才打通现有产品主线。

### 7.2 Phase 1 文件清单

#### Core 新增（`Sources/ProjectMemoryCore/`）

- `URLDenyList.swift` — 从 App 迁来 + 重命名 + `normalizeForDedup` 收进类型
- `ActivityDenyList.swift` — §5.6 默认列表 + `isDenied(bundleID:extraDenied:)`
- `ActivityGate.swift` — `Decision`、`decide(candidate:now:lastCaptureAt:extraDenied:)`，纯函数
- `ActivityClassifier.swift` — bundleID 路由表 + browser URL host 覆盖

#### Core 修改

- `Models.swift` — 追加 `ActivityCategory` / `ActivityCandidate` / `ActivityFrame` / `ProjectFilter`
- `MemoryStore.swift` — schema 加 `activity_frames` + 三索引；新增 `saveActivityFrame` / `fetchActivityFrames` / `countActivityFrames` / `deleteActivityFrames`

#### App 新增（建议子目录 `Sources/ProjectMemoryApp/Activity/`）

- `Activity/ActivityCoordinator.swift` — 编排（@MainActor）
- `Activity/ActivityCandidateCollector.swift` — `internal protocol ActivityCandidateCollecting` + 真实实现 `MacOSActivityCandidateCollector`，调 NSWorkspace + AX + BrowserTabReader（Coordinator 注入 protocol，测试用 `StubActivityCandidateCollector`）
- `Activity/ActivityTickScheduler.swift` — protocol + `TimerTickScheduler` 实现
- `Activity/Providers.swift` — IdleState / ScreenLockState / FrontmostApp 三 protocol + macOS 实现
- `Activity/AutomationAttemptLog.swift` — last-attempt 持久化
- `Activity/ActivityRetentionGC.swift` — 启动 +5s + 每 24h 触发
- `BrowserTabReader.swift` — protocol + `OSABrowserTabReader` 实现
- `Views/Settings/ActivitySection.swift` — Settings 子视图（建议拆分以保 SettingsView.swift 简洁）

#### App 修改

- `AppState.swift`：
  - 新增 `@Published activityCaptureEnabled` / `activityExtraDenied`，UserDefaults 持久化
  - 新增 `setActivityCaptureEnabled(_:)` / `addActivityExtraDenied(_:) / removeActivityExtraDenied(_:)`（含输入校验）
  - 新增 `private var activityCoordinator: ActivityCoordinator?` + `syncActivityCoordinator()`（实时 start/stop）
  - 现有 `persistAutoWebCapture` 中 `AutoWebCaptureDenyList` 调用替换为 `URLDenyList`
- `Views/SettingsView.swift`：嵌入 `ActivitySection`
- `AutoWebCaptureService.swift`：通过注入 `BrowserTabReader` 取 URL+title，不再自己 osascript

#### App 删除

- `AutoWebCaptureDenyList.swift`（已迁 Core）

#### Package.swift

确认 testTarget `ProjectMemoryAppTests` 存在且 dependencies 含 `ProjectMemoryApp`；若不存在则新增；若 dependencies 不足则补全。实施前先 `grep ProjectMemoryAppTests Package.swift` 验证。

#### Tests 新增

| 文件 | 估测 case 数 | 内容 |
|---|---|---|
| `Core: URLDenyListTests.swift` | ~5 | 从 `AutoWebCaptureTests` 迁来 |
| `Core: ActivityDenyListTests.swift` | ~6 | default / extraDenied / 边界 |
| `Core: ActivityGateTests.swift` | ~6 | capture/skip 矩阵 |
| `Core: ActivityClassifierTests.swift` | ~9 | 优先级矩阵 |
| `Core: ActivityFramesStoreTests.swift` | ~10 | save/fetch/count/delete + 各 filter |
| `Core: BriefGeneratorIsolationTests.swift` | 1 | guard 测试，详见 §8.2 |
| `App: BrowserTabReaderTests.swift` | ~3 | 成功/失败写 attemptLog / unsupported 抛错 |
| `App: AutomationAttemptLogTests.swift` | ~3 | 多 browser 隔离 / 序列化往返 / 状态过渡 |
| `App: ActivityCoordinatorTests.swift` | ~8 | manual tick / idle / lock / self-front / capability degradation / rate-limit / env flag off |
| `App: ActivitySettingsTests.swift` | ~4 | extraDenied 输入校验 4 result |

#### Tests 修改

- `App: AutoWebCaptureTests.swift` — 删 deny-list / normalize 两类（已迁），保 `SupportedBrowser` routing；新增 1 case：`AutoWebCaptureService` 使用注入的 `BrowserTabReader` mock

**Phase 1 新增 ~46 case，总数 47 → ~93。**

### 7.3 Phase 1 不动的代码

`BriefGenerator` / `AnswerEngine` / `OpenRouterClient` / `SourceSnippetSelector` / `KeychainStore` / `TextSanitizer` 全部零改动 — Phase 1 不接 brief / Q&A / OpenRouter 的边界保持。

### 7.4 Phase 1 Done 标准

1. `swift test` 全绿，47 → ~93
2. `swift build` clean，无 deprecated warning
3. `rg "AutoWebCaptureDenyList" Sources Tests Package.swift` 0 命中（迁移完成；不扫 docs/ 避免 spec 自引用 false positive）
4. `rg "normalizeURLForDedup" Sources Tests Package.swift` 0 命中（旧自由函数已改为 `URLDenyList.normalizeForDedup` 静态方法）
5. AppState 现有 `addWebCapture` / `persistAutoWebCapture` 行为零变（既有 dogfood 路径不影响）
6. 手动 smoke test 全过（§7.5）

### 7.5 手动 smoke test（须在真实 Mac 上跑）

**前置**：
- 先点 Settings → "清除所有活动记录"（或确认 `~/Library/Application Support/ProjectMemory/memory.sqlite` 中 `activity_frames` 为空），避免历史数据干扰

**步骤**：

1. `PROJECT_MEMORY_ENABLE_ACTIVITY_CAPTURE=1 swift run ProjectMemoryApp`（Xcode 用户走 Scheme env）
2. Settings tab → 启用活动记录 toggle
3. 切到 Chrome 看 `https://swift.org` 60 秒以上
4. 切到 Slack 60 秒以上
5. 切回 ProjectMemoryApp，Settings debug readout 应显示"今日捕获：≥2 帧"。SQLite 查 `activity_frames`：至少 2 行，Chrome 行 `category='work'` + `browser_url='https://swift.org'`，Slack 行 `category='chat'`
6. ProjectMemoryApp 在前台保持 60 秒：SQLite 不增加新行（self-pause 验证）
7. **Idle pause**：Slack 前台保持 6 分钟（不点鼠标不敲键盘）。前 ~5 分钟可正常出现 Slack 帧（每 60s 一帧）；idle ≥ 5min 触发 pause 后不应再有新 Slack 帧。验证：SQLite 查 Slack frame，最后一条 `observed_at` 应早于"进入 Slack 时刻 + 5min"之后的下一个 tick 边界

### 7.6 Phase 1 ship 后的状态

- 默认（不设 env flag）→ Project Memory 行为和现在 99% 等价（除了 `URLDenyList` 类型名变了，对 user 透明）
- 设 env flag + toggle on → 后台静默记录 metadata，用户感知是 Settings 里的 debug readout
- 用户唯一能"用上"这些数据：直接查 SQLite，或读 debug readout

**这意味着 Phase 1 ship 后无法直接 dogfood**（数据写了但产品上用不上）。**这是有意的**：
- 先把 capture pipeline 跑稳一周（生产数据观察 idle/lock/permission 边缘 case）
- Phase 2 接入 brief 之前先看真实数据形态，再决定 session 聚合粒度

## 8. 测试策略

### 8.1 测试金字塔

| 层 | 速度 | 跑在哪 | 覆盖 |
|---|---|---|---|
| Core 单测 | <5ms / case | 每次 `swift test` | 纯函数：gate / classifier / deny-list / store schema |
| App 单测 | <50ms / case | 每次 `swift test` | Coordinator + collector，依赖全 mock |
| Mechanical (eval) | <5ms / case | 每次 `swift test` | privacy 边界（已有 PrivacyBoundaryTests，**Phase 1 不新增**） |
| 手动 smoke | 5-10 min | 人工，每次 ship 前 | 真实 macOS NSWorkspace / osascript / idle / lock |

### 8.2 BriefGeneratorIsolationTests（guard）

测试名：`testDailyBriefPromptDoesNotIncludeActivityFrameContent`

构造：
- 真实 in-memory `MemoryStore`
- save 几条 `activity_frames`，bundleID `com.tinyspeck.slackmacgap`、windowTitle `"私人对话 alice"`、browserURL `https://example.com/secret`
- 调当前 brief 构造路径（`BriefGenerator().makeDailyBriefPrompt(projects:sources:events:)`，sources/events 不含任何 activity）

断言：
- 返回的 prompt 字符串不包含 `com.tinyspeck.slackmacgap`
- 不包含 `"私人对话 alice"`
- 不包含 `https://example.com/secret`

意图：未来如果有人不小心把 activity_frames 数据流接进 brief，这个测试会立刻 fail。是 future-proof guard，不算 mechanical assertion。

### 8.3 Mock catalog（test target）

```swift
final class ManualTickScheduler: ActivityTickScheduler {
    private var onTick: (() -> Void)?
    func start(onTick: @escaping () -> Void) { self.onTick = onTick }
    func stop() { onTick = nil }
    func fire() { onTick?() }                // 测试 API
}

struct StubIdleStateProvider: IdleStateProvider {
    var seconds: TimeInterval
    func secondsSinceLastUserInput() -> TimeInterval { seconds }
}

struct StubScreenLockStateProvider: ScreenLockStateProvider {
    var locked: Bool
    var isScreenLocked: Bool { locked }
}

struct StubFrontmostAppProvider: FrontmostAppProvider {
    var bundleID: String?
    var frontmostBundleID: String? { bundleID }
}

final class StubBrowserTabReader: BrowserTabReader {
    var result: Result<(title: String, url: String), Error>
    init(result: Result<(title: String, url: String), Error>) { self.result = result }
    func readActiveTab(bundleID: String) throws -> (title: String, url: String) { try result.get() }
}

final class StubActivityCandidateCollector: ActivityCandidateCollecting {
    var nextCandidate: ActivityCandidate?
    init(nextCandidate: ActivityCandidate? = nil) { self.nextCandidate = nextCandidate }
    func collect(now: Date) -> ActivityCandidate? { nextCandidate }
}
```

Coordinator tests 默认用 `StubActivityCandidateCollector` 喂入 canned 数据，**不**依赖真实 AX / BrowserTabReader / NSWorkspace；专项 collector 测试单独走 `BrowserTabReaderTests` 等。

### 8.4 ActivityCoordinatorTests 注入说明

**不**在测试里改 `ProcessInfo.processInfo.environment`。给 Coordinator 注入：

```swift
init(
    isRuntimeEnabled: @escaping () -> Bool,
    isUserEnabled: @escaping () -> Bool,
    scheduler: ActivityTickScheduler,
    idleStateProvider: IdleStateProvider,
    screenLockStateProvider: ScreenLockStateProvider,
    frontmostAppProvider: FrontmostAppProvider,
    selfBundleID: String,
    collector: ActivityCandidateCollecting,
    store: MemoryStore,
    extraDenied: () -> Set<String>,
    now: () -> Date = Date.init
)
```

测试直接传 closures 返回 `false` / `true`，零真实环境依赖。

### 8.5 In-memory store 复用

`MemoryStore.inMemory()` 已有；每个 case 起独立 store → 无 fixture 污染。

### 8.6 Phase 1 不测试范围（明示）

- 真实 `NSWorkspace.frontmostApplication` → 仅手动 smoke
- 真实 `osascript` 调 Safari/Chrome → 仅手动 smoke + `BrowserTabReader` mock 单测
- 真实 `CGEventSource` idle 计算 → 仅手动 smoke + `IdleStateProvider` mock
- 真实锁屏通知 → 仅手动 smoke + `ScreenLockStateProvider` mock
- Vision OCR → Phase 1.5
- 24h retention GC 真实定时器 → 通过 `ActivityRetentionGC.runOnce()` 入口做单测，不等 24h
- Brief / Q&A / OpenRouter → 不接，无新测试（`BriefGeneratorIsolationTests` 仅验证"没接"）

### 8.7 Eval rig 影响

- Phase 1 **不**改 `BriefGenerator` / `AnswerEngine` / `SourceSnippetSelector` / `OpenRouterClient`，现有 7 个 `PrivacyBoundaryTests` 全部保留，零修改
- Phase 1 **不**新增 mechanical assertion — 没有任何新数据进 prompt
- `BriefGeneratorIsolationTests`（§8.2）是 future-proof guard，不是 mechanical assertion

## 9. 实施提醒（codex review 留下的细节）

1. **Timer + main run loop**：
   - `ActivityCoordinator` 标 `@MainActor`（和 `AppState` 一致）
   - `TimerTickScheduler.start()` 内部调 `Timer.scheduledTimer(...)`，因 `@MainActor` 上下文 timer 落在 main run loop
   - 如果 Coordinator 之后改非 MainActor，需在 `TimerTickScheduler` 显式 `RunLoop.main.add(timer, forMode: .common)`
   - 测试用 `ManualTickScheduler`，不涉及 RunLoop

2. **可见性收紧**：
   - `BrowserTabReader` protocol、`OSABrowserTabReader` 实现、`StubBrowserTabReader` 测试 stub、`IdleStateProvider` / `ScreenLockStateProvider` / `FrontmostAppProvider` 三 protocol — 全部 `internal`（默认级别）
   - 测试通过 `@testable import ProjectMemoryApp` 访问
   - 不暴露到 product binary 之外

3. **Smoke test 前置清库**：
   `§7.5` 步骤 1 之前，先点 Settings → "清除所有活动记录"，或人工删除 `~/Library/Application Support/ProjectMemory/memory.sqlite` 中 `activity_frames` 表数据，避免历史 row 干扰判断。

## 10. 开放问题 / 推到后续

- Phase 1 ship 后是否要加"Phase 1.1"快速 dogfood 入口（比如 SQL 查询 cheatsheet 或更丰富的 Activity timeline 视图）— 视 Phase 1 跑稳一周后的实际信号决定
- LLM-based 分类是否值得做 — 等 Phase 1 真实数据看 bundleID + URL host 规则覆盖率
- Tier 2（capture-but-local-only）的具体语义 — 等 Phase 2 brief 整合后再讨论是否需要
- 银行 / 公司内部 app 的 deny-list 默认 — 可能用 LSCopyAllRoleHandlersForContentType 或公开 bundle ID 数据库自动发现，但 Phase 1 不做
- macOS 14 → 15 / 26 兼容（特别是 `CGEventSource` API 演进） — 监测，需要时再迁

## 11. 参考

- 现有 spec：`docs/superpowers/specs/2026-05-06-project-memory-design.md`
- 现有 plan：`docs/superpowers/plans/2026-05-06-project-memory-mvp.md`
- 现有 eval design：`docs/eval/eval-design.md`
- 现有 eval rubrics：`docs/eval/rubrics.md`
- Phase A（auto web capture）已 ship：`Sources/ProjectMemoryApp/AutoWebCaptureService.swift`（Phase 1 中将通过 `BrowserTabReader` 共享 osascript 路径）+ `AutoWebCaptureDenyList.swift`（Phase 1 中迁移到 `Sources/ProjectMemoryCore/URLDenyList.swift`）
- TextSanitizer (P5)：`Sources/ProjectMemoryCore/TextSanitizer.swift`
