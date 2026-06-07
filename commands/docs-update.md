---
description: 检查代码改动并同步更新文档（docs/、README、CLAUDE.md）
---

目标：派出 `docs-maintainer` 子 agent 检查自上次文档更新点以来的代码改动并更新文档。为避免无谓的二次派发，冷启动的用户交互在此（主线程）先完成，再**一次性**派出 agent。

## 步骤

1. **先判断是否冷启动**：检查目标仓库是否存在 `.docs-assistant/state.json`。
   - **不存在（冷启动）**：用 AskUserQuestion 让用户在两个起点中选择：
     - A) 补齐历史文档：从仓库首个提交开始全量梳理并对齐文档；
     - B) 从当前 HEAD 起算：仅记录基线，之后只维护增量。
     同时，若仓库缺少 `CLAUDE.md`，转达用户：可运行内置 `/init` 生成。
     拿到选择后，用 Task 工具派出 `docs-maintainer`，并在任务里**写明用户选了 A 还是 B**。
   - **已存在**：直接用 Task 工具派出 `docs-maintainer`，让它按自身流程跑增量更新。

2. **转达结果**：子 agent 完成后，把它的汇报转达给用户——改了哪些文档、是否新增 docs-map 条目、本次**本地提交**的 commit message 与 SHA、书签指向哪个 SHA。提醒用户：改动已本地提交（未 push），可在 `git push` 前用 `git log` / `git show` 复查，不满意可 `git reset` 回退。

> 说明：本命令不依赖 SendMessage 续接 agent；冷启动决策在主线程先做完，agent 始终单次派发。
