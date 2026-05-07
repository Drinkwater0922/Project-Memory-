# Project Memory Eval Rig — Design

日期：2026-05-06（v2，基于 codex 工程 review 修订）
作者：Claude (SE + 评测工程师)
状态：等 user 拍板进入 Step 3

## 1. 目标 / 非目标

**目标**：每次 codex 改 prompt / SourceSnippetSelector / OpenRouterClient / 任何影响生成质量的代码，自动给出"质量是否回退"的可量化信号；privacy boundary 必须是机械可证伪的（不依赖 LLM-judge）。

**非目标**：
- 不做 fine-tuning，没有"训练集"；只有 dev set / eval set / vibe set。
- 不做模型对比 benchmark，subject 模型固定为当前生产配置（`openai/gpt-4o-mini`）。
- 不做实时监控，runner 是按需 / pre-merge 触发。

## 2. 三层评测

| 层 | 何时跑 | 是否依赖 OpenRouter | 阻断策略 |
|---|---|---|---|
| **机械层** | 每次 `swift test` | 否 | 失败即 block merge |
| **LLM-judge 层** | codex 改动想合并前；release 前 | 是（subject + judge 各一次调用）| 任一维度 mean 跌 ≥ 1.0 → 人工 review；by-task 降档全部记录到 report；不自动 block |
| **Vibe set 层** | 每个迭代周期末（用户自己跑）| 是 | 用户主观判断；不进 CI |

## 3. Fixture 格式（多项目）

**Brief 是跨项目的**，所以一个 fixture 必须能包含多个 project，否则测不到"多项目覆盖不均"这种真实问题。

```
Tests/Fixtures/<fixture_id>/
├── manifest.json                # { id, version, description, tags: [...], kind: "synthetic"|"real" }
├── projects/
│   ├── <project_id_1>/
│   │   ├── meta.json            # { name, root_path_hint }
│   │   ├── files/               # 导入为该 project root 的文件树
│   │   │   ├── README.md
│   │   │   └── docs/plan.md
│   │   ├── captures/            # 该项目的网页捕获
│   │   │   └── 001.json         # { title, url, text, captured_at }
│   │   └── git/                 # 可选；Phase 2 再做
│   │       └── commits.jsonl
│   └── <project_id_2>/
│       └── ...
├── tasks.json                   # 跑哪些 brief / question；question 必须显式指定 project_id
└── ground_truth.json            # rubric judge 用的预期输出
```

`manifest.json`：
```json
{
  "id": "feature-x-multi",
  "version": "1",
  "description": "two parallel projects with overlapping themes",
  "tags": ["multi-project", "synthetic"],
  "kind": "synthetic"
}
```

`kind` 字段是 [Should-fix #1] 的核心：`synthetic` fixtures 允许把完整 source 喂给 judge；`real`（vibe）fixtures 默认禁止，必须显式 `--allow-full-source-judge` 才能开。详见 rubrics.md §1。

`tasks.json`：
```json
{
  "briefs": [
    { "id": "daily-global", "scope": "global" },
    { "id": "project-1-only", "scope": "project", "project_id": "<project_id_1>" }
  ],
  "questions": [
    { "id": "q1", "project_id": "<project_id_1>", "text": "这个项目我上次做到哪了？" },
    { "id": "q2", "project_id": "<project_id_2>", "text": "上周之后发生了什么变化？" }
  ]
}
```

`question.project_id` 必须显式给出 project_id 字符串（必须能在 `projects/` 下找到对应目录）；不再支持 `"auto"`。

`ground_truth.json` 字段语义详见 rubrics.md。`must_mention` 等字段从字符串改为结构化对象（[Should-fix #4]）：

```json
{
  "briefs": {
    "daily-global": {
      "must_mention": [
        { "text": "plan.md 里的未闭环 TODO", "priority": "primary", "evidence_paths": ["projects/<id_1>/files/docs/plan.md"] },
        { "text": "feature-x 分支当前状态", "priority": "secondary", "evidence_paths": [] }
      ],
      "expected_actions": [
        { "text": "完成 task 8 的 SwiftUI shell", "evidence_paths": ["projects/<id_1>/files/docs/plan.md"] }
      ],
      "must_not_say": ["编造的版本号", "不存在的 commit"],
      "decisions_to_recover": [
        { "text": "选 SQLite 而不是 CoreData 的原因", "evidence_paths": ["projects/<id_1>/files/docs/architecture.md"] }
      ]
    }
  },
  "questions": {
    "q1": {
      "expected_evidence_paths": ["projects/<id_1>/files/docs/plan.md"],
      "expected_answer_summary": "task 7 完成 SwiftUI shell 后停下，next 是 task 8。",
      "should_refuse": false
    }
  }
}
```

约束 4 落地：fixtures **结构和 manifest** 第一轮全部设计完；fixtures **真实内容** 第一轮只填 1-2 个跑通端到端，其余 placeholder。

## 4. SwiftPM Target 结构

[Blocker #2 + #3] codex 工程 review 拍的最终结构：

```
Package.swift 新增：
├── library  ProjectMemoryEvalSupport      # eval 共享代码 + 机械断言库
└── executable  ProjectMemoryEval          # CLI runner

Sources/
├── ProjectMemoryCore/                     # 现有；新增 FolderImportService
│   ├── FolderImportService.swift          # 从 AppState.performFolderImport 抽出来
│   └── ...（现有文件）
├── ProjectMemoryApp/
│   ├── AppState.swift                     # 改为调 FolderImportService，不再持有 import 逻辑
│   └── ...
├── ProjectMemoryEvalSupport/              # 新建 library target
│   ├── MechanicalAssertions.swift         # 隐私 / 引用格式 / snippet cap 断言
│   ├── FixtureLoader.swift                # 解析 Tests/Fixtures/<id>/
│   ├── EvalRunner.swift                   # 编排 import → generate → judge
│   ├── JudgeClient.swift                  # 调 judge 模型，解析 JSON 评分（Phase 2）
│   └── Report.swift                       # JSON 输出 schema
└── ProjectMemoryEval/                     # 新建 executable target
    └── main.swift                         # CLI 解析 + 调 EvalRunner

Tests/ProjectMemoryCoreTests/
├── PrivacyBoundaryTests.swift             # 新增；@testable import ProjectMemoryEvalSupport
└── ...（现有）
```

**关键工程决策（按 codex 答复）**：
- `ProjectMemoryEvalSupport` 是 internal library，能被 executable 和 test target 同时 import。executable 内部源码不可被 test 引用，所以机械断言不能放 executable target。
- `Package.swift` 加一个 `.executable` product 让 `ProjectMemoryEval` 可独立构建。
- `FolderImportService` 落进 core：原 `AppState.performFolderImport` 拆出无 UI 状态的纯逻辑（`scanner` → `parser` → `findSource` → `saveSource` → `saveTimelineEvent` → `GitActivityReader` → 收集 warnings），暴露给 AppState 和 EvalRunner 共用。AppState 只负责包一层 isLoading / errorMessage。

**API key**：runner 从环境变量 `OPENROUTER_API_KEY` 读，**绝不读 Keychain**（runner 是开发工具，不模拟用户态）。

**CLI 形态**（Phase 2 才完整实现，Phase 1 只搭骨架）：
```bash
swift run ProjectMemoryEval --fixture Tests/Fixtures/feature-x-multi
swift run ProjectMemoryEval --dev-set --output docs/eval/runs/<auto>.json
swift run ProjectMemoryEval --diff <run-a.json> <run-b.json>
swift run ProjectMemoryEval --fixture <real-vibe-fixture> --allow-full-source-judge
```

## 5. 输出 JSON Schema

[Blocker #4 + Should-fix #2] 修复：示例只用 0/3/5；scores 用 array of objects 保证维度顺序稳定；object key 全局 `.sortedKeys`；`git_sha` 拆三字段。

下面例子按 `JSONEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]` 输出后的真实 key 顺序排列（顶层 key 字母升序）：

```json
{
  "aggregate": {
    "by_dimension_mean": [
      { "dimension": "faithfulness",            "mean": 5.0 },
      { "dimension": "citation",                "mean": 5.0 },
      { "dimension": "coverage",                "mean": 3.0 },
      { "dimension": "refusal",                 "mean": 5.0 },
      { "dimension": "refusal_when_applicable", "mean": 5.0, "applicable_count": 0 },
      { "dimension": "action_quality",          "mean": 5.0 },
      { "dimension": "privacy_boundary",        "mean": 5.0 }
    ],
    "by_fixture_min": [
      { "fixture_id": "feature-x-multi", "min": 3 }
    ],
    "mechanical_pass_rate": 1.0,
    "tier_downs_vs_baseline": []
  },
  "config": {
    "snippet_max_length": 1200,
    "snippet_selector_brief_limit": 12,
    "snippet_selector_question_limit": 8
  },
  "fixtures": [
    {
      "fixture_id": "feature-x-multi",
      "fixture_kind": "synthetic",
      "fixture_version": "1",
      "tasks": [
        {
          "mechanical": [
            { "name": "privacy_no_full_extractedtext",     "result": "pass" },
            { "name": "privacy_truncation_marker_present", "result": "pass" },
            { "name": "snippet_count_within_cap",          "result": "pass" },
            { "name": "citation_format_present",           "result": "pass" }
          ],
          "prompt_hash": "<sha256(prompt + '\\n---\\n' + subject_model)>",
          "prompt_token_estimate": 1843,
          "scores": [
            { "dimension": "faithfulness",     "score": 5, "justification": "..." },
            { "dimension": "citation",         "score": 5, "justification": "..." },
            { "dimension": "coverage",         "score": 3, "justification": "..." },
            { "dimension": "refusal",          "score": 5, "justification": "n/a — should_refuse=false" },
            { "dimension": "action_quality",   "score": 5, "justification": "..." },
            { "dimension": "privacy_boundary", "score": 5, "justification": "all mechanical assertions pass" }
          ],
          "subject_latency_ms": 2104,
          "subject_response": "<full response text>",
          "task_id": "daily-global",
          "task_kind": "brief"
        }
      ]
    }
  ],
  "git_available": true,
  "git_dirty": false,
  "git_sha": "<hex sha or null>",
  "judge_model": "anthropic/claude-opus-4-7",
  "run_id": "<uuid>",
  "schema_version": "1.0.0",
  "subject_model": "openai/gpt-4o-mini",
  "timestamp": "2026-05-06T18:30:00Z"
}
```

**顶层字段说明**（展开后再排序，本节按业务分组讲解）：
- 标识：`schema_version` `run_id` `timestamp`
- 模型：`subject_model` `judge_model`
- 仓库状态：`git_available` `git_dirty` `git_sha`（三字段，详见下方）
- 配置：`config`
- 数据：`fixtures` `aggregate`

**编码策略**（按 codex 答复）：
- 全局 `JSONEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]`：所有 object key 按字母排序
- 需要保证顺序的（维度、机械断言）一律用 array of objects
- 不依赖 Codable 手写 encode 顺序（codex 指出该方案不可靠）

**`git_sha` 三字段** [engineering Q4]：
- `git_available: Bool` — 工作目录是不是 git repo
- `git_dirty: Bool` — working tree 有无未提交改动
- `git_sha: String?` — HEAD sha；非 git repo 时 `null`，不再用 `"dirty"` 字符串伪装

**关于 prompt_hash**：纯函数 of `prompt_text + "\n---\n" + subject_model`，不算时间戳。同 prompt + 同 model 应该 hash 一样。

**关于 `refusal_when_applicable`**（[Should-fix #5]）：
- `by_dimension_mean.refusal` 包含 `should_refuse=false → 5` 这种"白送分"，主要用于"看 task 是否做了拒绝判断"
- `by_dimension_mean.refusal_when_applicable` 只在 `should_refuse=true` 的 task 上算 mean，附 `applicable_count`；这个才是判断拒绝能力的主要指标
- 两个都展示，主要看后者

**`tier_downs_vs_baseline`**：array，记录所有相对 baseline 出现降档的 (fixture_id, task_id, dimension) 三元组。空数组 = 没有 task 级降档。这是新增的 by-task 监控（Should-fix 引申出来的，对应"任意降档触发 review"在三档制下的执行方式）。

## 6. swift test 集成（机械层）

新文件 `Tests/ProjectMemoryCoreTests/PrivacyBoundaryTests.swift`，`@testable import ProjectMemoryEvalSupport`：

- `testBriefPromptDoesNotContainFullExtractedText`
- `testQuestionPromptDoesNotContainFullExtractedText`
- `testBriefPromptIncludesTruncationMarkerWhenSourceExceedsLimit`
- `testQuestionPromptIncludesTruncationMarkerWhenSourceExceedsLimit`
- `testBriefSnippetCountWithinCap`（≤ 12）
- `testQuestionSnippetCountWithinCap`（≤ 8）
- `testCitationFormatTokensPresent`（"路径："、"URL：" 在 prompt 模板里）

约束 3 落地核心：`MechanicalAssertions.assertNoFullExtractedTextLeak(prompt:, sources:, snippetMaxLength: 1200)` —— 函数同一份代码，runner 跑 fixture 后调一次，test 用合成 sources 调一次。

## 7. Baseline + 阈值策略

[Should-fix #3] 双文件：
- `docs/eval/baseline.json` — runner 自动 diff 用的机器可读 pin（schema 同 §5）
- `docs/eval/baseline.md` — 人读摘要，引用 baseline.json 路径 + 当时 git_sha + 主要变化原因

**阈值规则**（约束 5 + Blocker #4 修订）：
- `mechanical_pass_rate < 1.0` → **block**（机械层零容忍）
- `by_dimension_mean` 任一维度跌 ≥ 1.0 → **人工 review**，红色警告
- `by_dimension_mean.refusal_when_applicable` 跌 ≥ 1.0 → **人工 review**（refusal 主指标用这个）
- `by_fixture_min` 任一 fixture 跌 ≥ 2.0 → **人工 review**
- `tier_downs_vs_baseline` 非空 → **report 中标黄**，但不阻断；提示作者描述哪些是预期变化

> 三档制下的"任意降档"语义：单 task 5→3 是降一档（绝对值 -2），mean 在 N=1 fixture 下确实 ≥ 1.0 触发 review；在 N=5 fixtures 下只移动 0.4，mean 不触发，但 `tier_downs_vs_baseline` 数组会标黄。两层兜住。

阈值都写在 `baseline.md` 里，不写死代码，方便迭代。

## 8. 工作流：codex 改动如何过 eval

```
1. codex 提改动
2. 我 code review (现有流程)
3. swift test 必须绿（含新机械断言）
4. 我跑：swift run ProjectMemoryEval --dev-set
5. 对比 baseline.json：
   - mechanical_pass_rate < 1.0 → block
   - by_dimension_mean 跌 ≥ 1.0 / refusal_when_applicable 跌 ≥ 1.0 / by_fixture_min 跌 ≥ 2.0 → 人工 review
   - tier_downs_vs_baseline 非空 → 标黄 + 让作者解释是不是预期
   - 否则 ✅，可合并
6. 合并后若是"目标性提升"，更新 baseline.json + 在 baseline.md 写理由
7. Vibe set 由你按节奏自己跑（real fixture 要 --allow-full-source-judge）
```

## 9. Phase 1 实现边界（窄）

按 codex 建议收紧：第一轮 Step 3 **只做下面这些**，不要把 OpenRouter judge runner 一起做完。

**Phase 1 in-scope**：
- `FolderImportService` 从 AppState 抽到 `ProjectMemoryCore`，AppState 改成调用方
- 新建 `ProjectMemoryEvalSupport` library target + `MechanicalAssertions.swift`
- 新建 `ProjectMemoryEval` executable target，CLI 只做骨架（`--help` 能跑，未实现的 flag 明确报 "Phase 2"）
- `Tests/ProjectMemoryCoreTests/PrivacyBoundaryTests.swift` — 全部 7 个机械断言
- `swift test` 必须绿
- `swift build` 必须绿
- 1 个真实 fixture（`Tests/Fixtures/feature-x-multi/`）的目录骨架 + manifest，不需要 ground_truth 内容

**Phase 1 out-of-scope（推到 Phase 2）**：
- `JudgeClient` 调 OpenRouter
- `EvalRunner` 端到端跑通
- `Report` JSON 输出
- baseline.json 生成
- `--diff` 命令
- ground_truth.json 真实内容
- Git 在 fixture 中的回放/抽象

**这样切的理由**：Phase 1 完成后，机械层的隐私断言已经在每次 `swift test` 跑，已经能拦截最严重的回退。LLM-judge 那部分等机械层稳了再做。

## 10. 还需要 codex 在 Step 3 实施时拍的工程问题

之前 §10 的工程问题大部分被 codex 这轮 review 直接答了。剩下还需要落地时确认的：

1. `FolderImportService` 抽出后，`AppState` 在 detached Task 里仍要重新打开 `MemoryStore(path:)` 吗？还是改成 service 自己持有 store 的弱引用 / actor？需要确认不破坏 `@MainActor` 边界。
2. `MechanicalAssertions` 的函数签名暴露给 test 时，是返回 `[AssertionResult]` 让 test case 自己 `XCTAssert` 解读，还是直接 throw？倾向前者，让 runner 的 mechanical 数组和 test 的失败原因都用同一个数据结构。
3. `Tests/Fixtures/` 目录被 SwiftPM 视作 resource 还是 source？测试访问 fixture 文件的标准做法（`Bundle.module` 还是相对路径）需要 codex 确认。
4. `kind: "synthetic" | "real"` 是否需要进 `manifest.json` 的 JSON Schema 强校验，避免漏标 real fixture 不小心被 judge 喂全文。

## 11. 不在本设计内 / 后续

- A/B 不同 prompt 版本对照
- 多 subject 模型 sweep
- Token 成本预算告警
- 自动从 vibe set 转 dev set 的 promotion 流程
- 评测结果可视化网页
- 长会话 / 多 turn Q&A 评测
