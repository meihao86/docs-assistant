---
description: 检查代码改动并同步更新文档（docs/、README、CLAUDE.md）
---

用 Task 工具派出 `docs-maintainer` 子 agent，让它按自身流程检查自上次文档更新点以来的代码改动并更新文档。

交互中转规则：
- 若子 agent 返回的是"冷启动决策请求"（首次运行，询问"补齐历史 / 从当前 HEAD 起算"），请用 AskUserQuestion 把这两个选项呈现给用户，拿到选择后，带着该选择重新用 Task 派出 docs-maintainer。
- 若子 agent 提示仓库缺少 CLAUDE.md，转达给用户：可运行内置 `/init` 生成。

子 agent 完成后，把它的汇报（改了哪些文档、是否新增 docs-map 条目、书签推进到哪个 SHA）转达给用户，并提醒用户用 `git diff` 复查文档改动后自行提交。
