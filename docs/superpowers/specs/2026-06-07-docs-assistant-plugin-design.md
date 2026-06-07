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
| 书签状态存储 | 独立文件 `.docs-assistant/state.json` | 不污染 CLAUDE.md 与会话 context，机器可靠读写 |
| 文档范围 | `docs/` + `README` + `CLAUDE.md` | 风险可控，不动源码 |
| 冷启动 | 先确保是 git 仓库（必要时 `git init`），再问用户：补历史 vs 从现在起算 | 书签/增量机制依赖 git，这是前置条件 |
| 缺少 CLAUDE.md | 提示复用内置 `/init` | 职责单一，不重造轮子 |
| 落地方式 | agent 直接编辑文档，用户用 `git diff` 复查 | 与"不阻断"一致，最顺畅 |
| docs-map 映射表 | 一期核心，"有则加速、无则回退" | 路由"改动→对应文档"，提升准确度并省扫描；带兜底故不增加风险 |
| docs-map 维护 | agent 半自动补充 | 发现新关系时建议/写入，表越用越准 |
| agent 模型 | Sonnet | 判断力与中文写作质量的甜点位，成本远低于 Opus |

## 3. 插件目录结构

```
docs-assistant/
├── .claude-plugin/
│   └── plugin.json              # 插件清单
├── agents/
│   └── docs-maintainer.md       # 子 agent 定义（model: sonnet）
├── commands/
│   └── docs-update.md           # /docs-update 手动触发
├── hooks/
│   ├── hooks.json               # PostToolUse 匹配 git commit/push
│   └── remind-docs.sh           # 注入"文档可能未同步"提醒（不阻断）
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

建议把 `.docs-assistant/state.json` 纳入版本管理，以便团队共享书签。

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

1. 读取目标仓库的 `.docs-assistant/state.json`。
2. **状态不存在（冷启动）**：
   - **检查目标仓库是否为 git 仓库**：若不是（无 `.git`），先执行 `git init` 初始化，并提示用户（整个书签/增量机制依赖 git，这是前置条件）。若工作区已有文件但无任何提交，需引导用户先建立首个 commit，否则没有可作为基线的 HEAD。
   - 询问用户：补齐历史文档，还是从当前 HEAD 起算。
   - 若仓库无 CLAUDE.md，提示用户用内置 `/init` 生成。
   - 写入基线 SHA 到 state.json。
3. **状态存在**：
   - 计算 `git diff <last_documented_commit>..HEAD`，得出区间内改动的代码路径。
   - **快速判断是否无需更新（见 5.2）**：若全部改动都落在"无需更新"情形 → 立即反馈"无需更新文档"，**仍推进 `last_documented_commit = HEAD`** 后退出，不进入后续步骤。
   - **查 `docs-map`（见 5.1）**：命中的路径 → 直接定位到关联文档作为更新候选。
   - **兜底**：未命中映射表的路径（或映射表不存在）→ agent 自行读 `tracked_paths` 下的文档，判断哪些受改动影响（接口、命令、配置、目录结构等变化）。
   - **直接编辑**相关文档文件。
   - 若发现新的"代码↔文档"关系，**半自动向 `docs-map` 补充条目**。
   - 更新 state.json：`last_documented_commit = HEAD`，刷新 `updated_at`。
4. 汇报：列出改了哪些文档、为什么、是否新增了映射条目；提示用户用 `git diff` 复查；文档改动留在工作区，由用户决定何时提交。

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

> 设计要点：即便判定"无需更新"，也必须把 `last_documented_commit` 推进到 HEAD，否则这些提交会在下次被重复评估。

## 6. 两个触发入口

### 6.1 `/docs-update`（手动）
- 主线程读取该 slash 命令 → 用 Task 工具派出 docs-maintainer 子 agent。

### 6.2 hook（自动）
- `hooks.json` 监听 `PostToolUse`，匹配 Bash 工具中成功执行的 `git commit` / `git push`。
- `remind-docs.sh` 向主线程注入一条提醒上下文，建议当场派出 docs-maintainer。
- **不阻断**提交；是否当场更新由主线程/用户决定。

## 7. 二期可选优化（YAGNI，暂不实现）

- **门槛过滤**：hook 触发时，先用纯脚本（或 Haiku）判断 diff 是否碰到关键路径，只有可能需要更新时才派 Sonnet agent，省掉大量空跑。
- **影响面分析增强**：判断"改了 X 影响哪些代码/文档"时，可考虑复用 CodeGraph 等现成的代码图谱工具（基于 AST 的调用图/impact 分析），而非自建；其输出可作为 docs-map 路由的上游，提升关联准确度。

## 8. 非目标

- 不维护源码内注释/docstring。
- 不做阻断式提交门禁。
- 不替代 `/init` 的 CLAUDE.md 生成。
