# Project Memory Eval Rubrics

日期：2026-05-06（v2，基于 codex 工程 review 修订）
作者：Claude (评测工程师)
状态：等 user 拍板进入 Step 3

配套文档：[eval-design.md](./eval-design.md)

## 1. 怎么用

每个 fixture 的每个 task（一个 brief 或一个 question）会被独立打分。

**Judge 看到 source 全文的策略**（[Should-fix #1] 修订）：

| Fixture `kind` | Judge 默认看到 | 例外 |
|---|---|---|
| `synthetic` | sources 完整 `extractedText` | 无；合成数据本来就不是真实隐私 |
| `real`（vibe set） | 仅 `ground_truth` 中显式列出的 `evidence_excerpts` | runner 加 `--allow-full-source-judge` 才发完整文本 |

> 这是产品隐私心智的延伸：用户的真实项目内容默认不应该被发去任何外部模型，包括 judge model。`real` fixtures 的 ground_truth 必须自己写好"哪些片段允许被评测看到"。Synthetic fixtures 是我们手写的假数据，没有这个约束。

**Judge prompt 模板**（具体内容根据 kind 切换 sources 部分）：

```
你是一个评测员。下面是一个 Project Memory 系统的输入和输出。
请只基于事实判断，给每个维度打分（0、3、5 三档；不允许打 1、2、4），并写一句简短的 justification。

任务类型：{brief | question}
任务内容（ground_truth）：
{must_mention / expected_actions / expected_evidence_paths 等结构化字段}

原始 sources：
{kind=synthetic 时：sources 完整列表，含 title / path / url / 完整 extractedText}
{kind=real 时：仅 ground_truth.evidence_excerpts，注明 "这是被允许评测的片段，全文受保护"}

被测系统的 prompt：
{prompt 全文}
被测系统的输出：
{response 全文}

请输出严格的 JSON：
{
  "faithfulness":   { "score": 0|3|5, "justification": "..." },
  "citation":       { "score": 0|3|5, "justification": "..." },
  "coverage":       { "score": 0|3|5, "justification": "..." },
  "refusal":        { "score": 0|3|5, "justification": "..." },
  "action_quality": { "score": 0|3|5, "justification": "..." } | null
}

注意：
- privacy_boundary 由机械断言决定，judge 不评分，整体不出现该字段。
- action_quality 仅适用于 brief；question 任务该字段输出 null。
- coverage 的判定标准在 brief 和 question 下不同，见各维度说明。
- 若 fixture kind=real 且未启用 --allow-full-source-judge，对 faithfulness/citation 的判定要承认"未见全文"的不确定性，必要时降一档而不是判 0。
```

**为什么只允许 0/3/5**：实践中 1/2/4 会让 judge 漂移、不同 run 之间不一致。三档锚点更稳。在三档制下"任意降档"等价于绝对分跌 ≥ 2，等价于单 fixture mean 跌 ≥ 2/N；这也是为什么 [eval-design.md §7] 用了双层阈值（dimension mean ≥ 1.0 触发 review + by-task `tier_downs_vs_baseline` 数组单独标黄）来兜底。

## 2. 维度总览

| 维度 | brief | question | 备注 |
|---|---|---|---|
| Faithfulness | ✅ | ✅ | 判定不同 |
| Citation | ✅ | ✅ | 判定不同 |
| Coverage | ✅ | ✅ | 判定差异最大 |
| Refusal | ✅ | ✅ | 同一标准 |
| Action quality | ✅ | ❌ | brief 专属 |
| Privacy boundary | 机械 | 机械 | LLM 不评分 |

## 3. 各维度 rubric

### 3.1 Faithfulness — Brief

判定：简报里的每条**事实性陈述**能否回溯到一条 prompt 里实际出现过的 snippet。

| 分 | 标准 |
|---|---|
| 5 | 简报中所有断言都能在 prompt 的 sources 片段或 timeline events 里找到直接依据。没有任何"看似合理但来源中并未提及"的内容。即使做了归纳/总结，也是对存在事实的归纳。 |
| 3 | 大部分断言可回溯，但存在 1-2 条**轻度推测**（不是凭空，但 source 里只有间接线索；或者过度归纳）。无主动错误事实。 |
| 0 | 出现至少一条**明确不在 source 中的事实**（编造日期 / 编造 commit message / 编造文件名 / 凭空总结决策原因）。或断言与 source 直接矛盾。 |

### 3.2 Faithfulness — Question

判定：回答中的每条事实能否回溯到 prompt 里实际出现过的 snippet。

| 分 | 标准 |
|---|---|
| 5 | 回答全部基于提供的 source。如果 source 不足以回答，使用了"证据不足"的措辞。 |
| 3 | 主体回答正确，但夹杂 1 条次要的推测/常识填充（如自己补了"通常"、"一般来说"）。无主动错误。 |
| 0 | 至少一条主张是 source 中没有的，或与 source 矛盾。 |

> Brief 和 Q&A 的差异：brief 允许"对多个 source 做归纳"，Q&A 必须"直接基于具体 source 回答"。Q&A 的归纳容忍度更低。

### 3.3 Citation — Brief

判定：关键结论是否带 `来源：《...》 路径：...` 引用，且引用真的指向**支持该结论的 source**。

| 分 | 标准 |
|---|---|
| 5 | 简报里每个非泛泛的关键结论（"未闭环 TODO"、"最近变化"、"下一步建议"）都带至少一个引用，引用的 title/path 在原 sources 列表里能找到，且**该 source 内容确实支持该结论**。 |
| 3 | 大部分关键结论带引用，但存在以下情况之一：(a) 1-2 条结论缺引用；(b) 引用的 path 真实存在但内容只**间接相关**（不是直接证据）；(c) 引用了正确的 path 但 title 拼错。 |
| 0 | 至少一处出现：引用了不存在的 path / 编造的 title；或核心结论全部裸奔无引用；或引用指向的 source 与该结论无关。 |

### 3.4 Citation — Question

判定：回答末尾或行内是否带引用，且引用的 source **包含回答的依据**。

| 分 | 标准 |
|---|---|
| 5 | 回答带至少一条 `来源：《...》 路径：...`（无 URL 时 `URL：无`），引用的 source 在 prompt 的 sources 里存在，且 ground_truth 中 `expected_evidence_paths` 至少有一条被引用。 |
| 3 | 引用存在但部分错位：(a) 引用了相关但非最优的 source；(b) `expected_evidence_paths` 命中数 < 一半；(c) 引用格式不规范但 path 正确。 |
| 0 | 无引用；或引用 path 不在 sources 中；或引用的 source 与回答内容无关。 |

### 3.5 Coverage — Brief

判定：`ground_truth.must_mention` 列出的关键事项有没有被简报覆盖。

| 分 | 标准 |
|---|---|
| 5 | 所有 `priority: "primary"` 的 `must_mention` 项全部被提及；`secondary` 命中 ≥ 50%；同时识别出 `decisions_to_recover` 中的至少一项；不出现 `must_not_say` 中的任何一项。 |
| 3 | 所有 `priority: "primary"` 项被提及，但 `secondary` 命中 < 50%；或 `primary` 漏 1 项但其余 primary 全部命中；`must_not_say` 不出现。 |
| 0 | 任一 `priority: "primary"` 项漏掉超过 1 条；或出现至少一条 `must_not_say`（编造内容）。 |

> [Should-fix #4] `must_mention` 在 ground_truth.json 里是结构化对象，不再用 `#primary` 后缀：
>
> ```json
> { "text": "plan.md 里的未闭环 TODO", "priority": "primary", "evidence_paths": ["projects/<id>/files/docs/plan.md"] }
> ```
>
> Judge 按 `priority` 字段判定档位，`evidence_paths` 用于辅助 citation 维度判定。

### 3.6 Coverage — Question

判定：回答有没有用到 ground_truth 标记的"应该用的证据"。

| 分 | 标准 |
|---|---|
| 5 | `expected_evidence_paths` 中至少 80% 在回答里被引用或其内容被使用；回答覆盖了 `expected_answer_summary` 的核心要点。 |
| 3 | `expected_evidence_paths` 命中 1 条但非全部；回答方向正确但有遗漏要点。 |
| 0 | `expected_evidence_paths` 一条都没用上；或回答跑题（用了无关 source）。 |

> Brief 的 coverage 看"广度"（must_mention 多项），Q&A 的 coverage 看"深度"（用对了证据没）。

### 3.7 Refusal（brief 和 question 同一标准）

判定：当 ground_truth 标记 `should_refuse: true`（证据不足以回答），系统是否正确拒绝。

| 分 | 标准 |
|---|---|
| 5 | 系统明确说"证据不足"或同义表达，**并指出还缺什么信息**。Brief 场景里对应"该项目近期无足够证据生成简报"+ 列出缺失的数据源。 |
| 3 | 系统拒绝了，但**没说缺什么**（"无法回答"裸奔）；或加了不必要的 hedge 但仍偏向给出答案。 |
| 0 | `should_refuse: true` 但系统给了一个看起来 confident 的回答（hallucinate）。**这是最严重的失败模式**。 |

> 当 `should_refuse: false` 时，refusal 维度直接打 5（不适用即满分）。
>
> [Should-fix #5] 但这会让 `by_dimension_mean.refusal` 虚高。Aggregator **必须**单独输出 `by_dimension_mean.refusal_when_applicable`，只在 `should_refuse=true` 的 task 上算 mean，并附 `applicable_count`（可能为 0）。判 review 时以 `refusal_when_applicable` 为准；`by_dimension_mean.refusal` 仅供参考。详见 [eval-design.md §5 / §7]。

### 3.8 Action Quality（仅 brief）

判定：简报末尾的 1-3 个"下一步建议"是否具体、可执行、有依据。

| 分 | 标准 |
|---|---|
| 5 | 给出 1-3 个 action，每个都满足：(a) 指明项目；(b) 动作具体（不是"继续推进"）；(c) 带引用或明确指向某 source；(d) 命中 ground_truth.expected_actions 至少一条。 |
| 3 | Action 数量在 1-3，但存在：(a) 1 个偏抽象（"完善文档"）；(b) 没全带引用；(c) expected_actions 命中 < 全部但 ≥ 1。 |
| 0 | Action 数量不在 1-3 范围；或全部抽象/无引用；或 expected_actions 一条都没命中。 |

### 3.9 Privacy Boundary（机械层，LLM 不评分）

每条机械断言独立 pass/fail，全 pass 才算 5 分；任一 fail 整个维度判 0 分（在 aggregate 里转换）。

| 断言 | 检查内容 |
|---|---|
| `privacy_no_full_extractedtext` | 对 prompt 中 sources 集合，若某 source 的 `extractedText.count > snippet_max_length`（默认 1200），则 prompt **不得**包含其完整 `extractedText` |
| `privacy_truncation_marker_present` | 同条件下，prompt 必须出现 `[内容已截断，仅发送相关片段]` 标记，且**至少出现一次/被截断的 source 一次** |
| `snippet_count_within_cap` | brief: prompt 中 source 块数 ≤ `selectForBrief` cap（12）；question: ≤ `selectForQuestion` cap（8） |
| `citation_format_present` | prompt 模板中包含 `路径：` 和 `URL：` 字段名（保证 response 有引用模板可循） |

**对应约束 3**：privacy_boundary 是产品最 load-bearing 的承诺。机械断言永远比 LLM judge 优先；机械层 fail → 整次 run 整体降级，不再展示其他维度分数（避免别的维度高分掩盖隐私失败）。

## 4. 聚合策略

**单 fixture 单 task**：每维度独立打分（0/3/5）。

**单 fixture 多 task**（一个 fixture 可能有 1 个 brief + 多个 question + cross-project brief）：
- 维度均值（mean per dimension across tasks）
- 输出 `by_task` 明细 + `fixture_aggregate`

**run 级聚合**（多 fixture）：
- `by_dimension_mean`：每维度跨 fixture 跨 task 取均值
- `by_dimension_mean.refusal_when_applicable`：仅在 `should_refuse=true` 的 task 上算 mean，附 `applicable_count`（可能为 0）。**Refusal 的主指标用这个，不用 `refusal`**。
- `by_fixture_min`：每 fixture 取所有维度最低分（发现"某个 fixture 整体很差"）
- `mechanical_pass_rate`：所有 task 的机械断言总通过率（pass/total，不是均值）
- `tier_downs_vs_baseline`：相对 baseline 的 by-task 降档列表，详见 [eval-design.md §5]

**为什么不加权**：早期所有维度等权，避免在还没看过 vibe 数据前就先验地说"faithfulness 比 coverage 重要"。等 vibe set 反馈进来后再决定加权。

## 5. Judge 模型选择

**首选**：`anthropic/claude-opus-4-7`（OpenRouter 上）

**理由**：
- subject 是 gpt-4o-mini（快、便宜，适合产品调用），judge 必须比 subject 强一个量级
- Opus 4.7 中文 judge 一致性比 Sonnet 高
- 同 vendor 一致性更好（避免 OpenAI judge 偏 OpenAI subject）

**Judge 自身的偏差怎么控**：
- 同一 fixture 多次跑（建议 3 次），取**中位数**作为最终分（不是均值，避免一次拍偏拉爆）
- 每次 run 输出 `judge_runs` 数组保留 3 次原始打分
- baseline 用 3 次中位数 pin

## 6. 留白 / Phase 2

- 多语言：当前 rubric 假设 prompt + response 都中文。如果未来支持英文项目，rubric 要分语种。
- Code-aware coverage：commit / diff 类 source 的 coverage 判定可能需要专门 rubric（"是否抓到关键 commit"）。
- 长会话 / 跟进追问：当前 question 只评单 turn。
- Self-consistency：subject 同 prompt 跑 3 次看是否一致，目前不评。

## 7. Step 3 实施时仍需 codex 留意的点

之前列的工程问题大部分被 codex review 直接答了或在 v2 中已修订（结构化 priority、refusal_when_applicable、judge sources 全文 gate）。剩下：

1. Judge prompt 在 synthetic fixture 下含完整 sources，token 量可能接近 judge model context 上限。Step 3 不实现 judge，但实施 Phase 2 时需要测量并加 fixture-level token budget 检查。
2. 中位数聚合在 0/3/5 三档 + 3 次 judge 跑下，[0,3,5] 中位数 = 3 看起来合理，但 [0,5,5] 中位数 = 5 可能掩盖一次极端 fail。Phase 2 可考虑用 "min of 3 runs" 而不是中位数；待真实数据出来后再定。
3. `justifications` 字段长度上限：建议 Phase 2 加 `max_justification_chars: 240` 配置项，超出截断 + 标记 `justification_truncated: true`。
4. `evidence_excerpts` 在 `real` fixture ground_truth 中如何方便地手写（比如允许 `{ path, char_offset, length }` 引用文件位置而不是粘贴全文）。Step 3 不需要，做 vibe set 时再设计。
