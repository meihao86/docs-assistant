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
| 冷启动 | 首次运行问用户：补历史 vs 从现在起算 | 由用户决定回填成本 |
| 缺少 CLAUDE.md | 提示复用内置 `/init` | 职责单一，不重造轮子 |
| 落地方式 | agent 直接编辑文档，用户用 `git diff` 复查 | 与"不阻断"一致，最顺畅 |
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

## 5. docs-maintainer agent 工作流

1. 读取目标仓库的 `.docs-assistant/state.json`。
2. **状态不存在（冷启动）**：
   - 询问用户：补齐历史文档，还是从当前 HEAD 起算。
   - 若仓库无 CLAUDE.md，提示用户用内置 `/init` 生成。
   - 写入基线 SHA 到 state.json。
3. **状态存在**：
   - 计算 `git diff <last_documented_commit>..HEAD`，得出区间内代码/文件改动。
   - 分析哪些改动影响 `tracked_paths` 下的文档（接口、命令、配置、目录结构等变化）。
   - **直接编辑**相关文档文件。
   - 更新 state.json：`last_documented_commit = HEAD`，刷新 `updated_at`。
4. 汇报：列出改了哪些文档、为什么；提示用户用 `git diff` 复查；文档改动留在工作区，由用户决定何时提交。

## 6. 两个触发入口

### 6.1 `/docs-update`（手动）
- 主线程读取该 slash 命令 → 用 Task 工具派出 docs-maintainer 子 agent。

### 6.2 hook（自动）
- `hooks.json` 监听 `PostToolUse`，匹配 Bash 工具中成功执行的 `git commit` / `git push`。
- `remind-docs.sh` 向主线程注入一条提醒上下文，建议当场派出 docs-maintainer。
- **不阻断**提交；是否当场更新由主线程/用户决定。

## 7. 二期可选优化（YAGNI，暂不实现）

- **门槛过滤**：hook 触发时，先用纯脚本（或 Haiku）判断 diff 是否碰到关键路径，只有可能需要更新时才派 Sonnet agent，省掉大量空跑。
- **doc-code 映射表**：显式声明"某模块 ↔ 某文档"，提升判断准确度。

## 8. 非目标

- 不维护源码内注释/docstring。
- 不做阻断式提交门禁。
- 不替代 `/init` 的 CLAUDE.md 生成。
