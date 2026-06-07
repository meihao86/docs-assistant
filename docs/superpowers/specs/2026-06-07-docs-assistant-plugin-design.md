# docs-assistant 插件设计文档

- 日期：2026-06-07
- 状态：已通过头脑风暴，待用户复核
- 目标环境：本地 Windows + WSL2，开发/调试用

## 1. 背景与目标

代码或文件改动后，对应文档常常忘记更新，导致文档与实现脱节。

本插件提供一个 **文档维护 agent（docs-maintainer）**，由主线程在 git 提交后派出，自动检测自"上次文档更新点"以来的代码改动，并把相关文档补齐。核心是一套"书签"机制：记录文档已经更新到哪个 commit，每次只处理增量。

维护范围：`docs/` 目录、`README`（根及子目录）、`CLAUDE.md`。**不碰源码注释/docstring**，以控制风险。

## 2. 核心设计决策

| 决策点 | 结论 | 理由 |
|---|---|---|
| 触发方式 | 手动 `/docs-update` + hook 自动提醒 | 既能随时调用，又能自动兜底 |
| hook 时机 | PostToolUse，git commit/push 成功后 | 与"提示不阻断"自洽；提交后有确定 SHA 可记录 |
| hook 行为 | 提示不阻断 | 不打断提交节奏 |
| hook 匹配 | 按 shell 分段解析，仅"段首为 git 且子命令为 commit/push"才触发 | 子串匹配会被引号/grep/echo 里的字样误触发（已实测踩坑） |
| 书签状态存储 | 独立文件 `.docs-assistant/state.json` | 不污染 CLAUDE.md 与会话 context，机器可靠读写 |
| 文档范围 | `docs/` + `README` + `CLAUDE.md` | 风险可控，不动源码 |
| 冷启动 | 先确保是 git 仓库（必要时 `git init`）；A/B 起点交互在命令（主线程）完成后**单次**派 agent | 书签/增量依赖 git；主线程先问可省一次派发，且不依赖 SendMessage |
| 缺少 CLAUDE.md | 提示复用内置 `/init` | 职责单一，不重造轮子 |
| 落地方式 | agent **定向自动提交**文档改动（仅文档 + `.docs-assistant/`），不 push；用户 push 前用 `git log`/`git show` 复查 | 保持工作区干净，避免上次文档改动残留污染下次提交 |
| 书签推进 | 只在"文档真有改动"时推进并提交书签；无需更新则不写不提交 | 自动提交下若每次都推进书签，会因书签提交自身又触发处理而死循环 |
| 未提交改动 | 算增量时同时 `git status` 检查工作区，纳入未提交代码改动或警告 | commit 区间 diff 看不到未提交改动，手动触发易漏 |
| 时间戳 | `updated_at` 用 `date -Iseconds` 取真实时间 | 不许编造 |
| docs-map 映射表 | 一期核心，"有则加速、无则回退" | 路由"改动→对应文档"，提升准确度并省扫描；带兜底故不增加风险 |
| docs-map 维护 | agent 半自动补充 | 发现新关系时建议/写入，表越用越准 |
| agent 模型 | Sonnet | 判断力与中文写作质量的甜点位，成本远低于 Opus |

## 3. 插件目录结构

```
docs-assistant/
├── .claude-plugin/
│   ├── plugin.json              # 插件清单
│   └── marketplace.json         # 单仓库即插件即 marketplace 的发布源定义
├── agents/
│   └── docs-maintainer.md       # 子 agent 定义（model: sonnet）
├── commands/
│   └── docs-update.md           # /docs-update 手动触发
├── hooks/
│   ├── hooks.json               # PostToolUse 匹配 git commit/push
│   └── remind-docs.sh           # 注入"文档可能未同步"提醒（不阻断）
├── tests/
│   └── test-remind-docs.sh      # remind-docs.sh 单元测试
├── docs/superpowers/            # 设计文档与实现计划（本仓库开发文档）
├── .gitignore
└── README.md
```

## 4. 状态文件

写在 **目标仓库**（被维护的项目）中，路径 `.docs-assistant/state.json`：

```json
{
  "last_documented_commit": "<sha>",
  "updated_at": "2026-06-07T00:00:00Z",
  "tracked_paths": ["docs/", "README.md", "CLAUDE.md"]
}
```

- `last_documented_commit`：文档已覆盖到的 commit SHA。
- `updated_at`：上次更新时间戳。
- `tracked_paths`：本仓库纳入维护的文档路径（可由用户按需调整）。

`.docs-assistant/state.json` 由 agent 在更新文档时一并定向提交，**必须纳入版本管理**（不可被 `.gitignore` 忽略），否则每次新克隆都会重新冷启动、团队也无法共享书签。

> 书签语义说明：`last_documented_commit` 记录的是 agent 运行那一刻的 HEAD，即**触发本次的代码提交**；agent 随后把文档改动提交为下一个 commit。因此稳态下 `last_documented_commit` 通常**落后 HEAD 一个文档提交**，这是预期行为，不是异常——纯文档/`.docs-assistant` 改动会被快速跳过（§5.2），不会被反复处理。

## 4.1 映射表文件 docs-map

同样写在目标仓库，路径 `.docs-assistant/docs-map.yaml`，声明"代码路径(glob) → 关联文档"：

```yaml
# 代码路径(glob)   → 关联文档
"src/auth/**":      ["docs/auth.md", "README.md#认证"]
"src/api/**":       ["docs/api/"]
"cli/**":           ["docs/cli.md", "README.md#命令行"]
```

定位：**"有则加速、无则回退"的优化层，不是硬依赖**。命中条目时直接定位到关联文档；未命中或文件不存在时，回退到 agent 自行读文档判断（见 5.3）。agent 在发现新的代码↔文档关系时，半自动地向该表补充条目（用户可在 `git diff` 中复查）。建议纳入版本管理。

## 5. docs-maintainer agent 工作流

0. **前置：确保是 git 仓库**：若不是（无 `.git`），先 `git init` 并提示用户（书签/增量机制依赖 git）。若有文件但无任何提交，引导用户先建立首个 commit（否则无可作基线的 HEAD）。
1. 读取目标仓库的 `.docs-assistant/state.json`。
2. **状态不存在（冷启动）**：通常 `/docs-update` 命令已在主线程问过用户并把 A/B 选择写进任务（§6.1）；agent 据此执行，A 从首个提交起、B 仅写基线。若未给出选择则返回决策请求由主线程询问。缺 CLAUDE.md 时提示用 `/init`。
3. **状态存在（增量）**：
   - 计算 `git diff --name-only <last_documented_commit>..HEAD`，得出区间内改动路径。
   - **同时 `git status` 检查工作区**：commit 区间 diff 看不到未提交改动，手动触发时把未提交的代码改动一并纳入分析，或提示用户先提交。
   - **快速判断是否无需更新（见 5.2）**：若全部改动都落在"无需更新"情形 → 立即反馈"无需更新文档"，**不写 state.json、不提交、不动书签**后退出。
   - **查 `docs-map`（见 5.1）**：命中路径 → 直接定位关联文档作为候选。
   - **兜底**：未命中（或无映射表）→ agent 自行读 `tracked_paths` 下文档，判断哪些受影响。
   - **直接编辑**相关文档；编辑前先确认确有不一致，避免无意义改写。
   - 若发现新的"代码↔文档"关系，**半自动向 `docs-map` 补充条目**。
4. **提交并推进书签（仅当第 3 步真的改了文档）**：
   - `updated_at` 用 `date -Iseconds` 取真实时间；`last_documented_commit = git rev-parse HEAD`。
   - **定向提交**：`git add` 仅本次改动的文档 + `.docs-assistant/state.json` +（如有）`docs-map.yaml`，再 `git commit`；**绝不 `git add -A/-u`**，**不 `git push`**。
   - 无需更新时跳过本步（不提交、不动书签），避免自动提交死循环。
5. 汇报：改了哪些文档及原因、是否新增映射条目、本次本地提交的 commit message 与 SHA、书签 SHA；提示用户 push 前用 `git log`/`git show` 复查，不满意可 `git reset` 回退。

### 5.1 docs-map 查表与兜底逻辑

- 读取 `.docs-assistant/docs-map.yaml`。
- 对每个改动路径，按 glob 匹配映射表条目：命中 → 收集其关联文档进入更新候选；未命中 → 进入兜底（agent 自行判断）。
- 映射表是优化层而非硬依赖：**文件缺失或条目不全都不应阻塞流程**，只是退化为全量判断、范围更大。

### 5.2 无需改动文档的情形（快速反馈）

agent 在工作流早期先做此判断，命中则立即反馈并退出（仍推进书签）：

**无需更新**：
- 纯内部重构，不改公开接口 / CLI / 配置 / 对外行为
- 测试文件改动（`test/`、`*_test.*`、`*.spec.*` 等）
- 格式化 / lint / import 排序 / 纯空白
- 注释拼写、变量重命名等不影响文档描述的改动
- 依赖版本微调且不改使用方式
- 构建产物、临时文件、被 `.gitignore` 的路径
- 改动仅发生在文档自身或 `.docs-assistant/`（避免自我循环）
- bug 修复但未改变文档所描述的行为

**必须更新**：公开 API / 函数签名、CLI 命令或参数、配置项、环境变量、目录结构、安装/使用步骤、任何对外行为变化。

> 设计要点：自动提交模式下，无需更新时**不写 state.json、不提交、不动书签**——若每次都推进书签会因"书签提交自身又触发处理"而死循环。书签因此只在文档真有改动时前移；其间的纯跳过提交会在每次运行被廉价地重新分类（`git diff --name-only` 级别），等下次文档真有改动时书签一次性跳到最新。

## 6. 两个触发入口

### 6.1 `/docs-update`（手动）
- 主线程读取该 slash 命令：先检查 `.docs-assistant/state.json` 是否存在。
- **冷启动（不存在）**：主线程用 AskUserQuestion 问用户 A/B 起点（并在缺 CLAUDE.md 时提示 `/init`），拿到选择后用 Task **单次**派出 docs-maintainer 并写明选择。
- **已存在**：直接用 Task 派出 docs-maintainer 跑增量。
- 如此把冷启动交互放在主线程，省去"先派一次只为问 A/B"的二次派发，也不依赖 SendMessage 续接 agent。

### 6.2 hook（自动）
- `hooks.json` 监听 `PostToolUse`，matcher 为 `Bash`。
- `remind-docs.sh` **精确判断**命令是否真的在执行 `git commit`/`git push`（按 shell 分段解析，避免子串误判），是则向主线程注入提醒上下文，建议当场派出 docs-maintainer。
- **不阻断**提交；是否当场更新由主线程/用户决定。

## 7. 二期可选优化（YAGNI，暂不实现）

- **门槛过滤**：hook 触发时，先用纯脚本（或 Haiku）判断 diff 是否碰到关键路径，只有可能需要更新时才派 Sonnet agent，省掉大量空跑。
- **影响面分析增强**：判断"改了 X 影响哪些代码/文档"时，可考虑复用 CodeGraph 等现成的代码图谱工具（基于 AST 的调用图/impact 分析），而非自建；其输出可作为 docs-map 路由的上游，提升关联准确度。

## 8. 非目标

- 不维护源码内注释/docstring。
- 不做阻断式提交门禁。
- 不替代 `/init` 的 CLAUDE.md 生成。
