# docs-assistant

维护项目文档的 Claude Code 插件。代码改动后，自动检查自"上次文档更新点"以来的提交，并同步更新 `docs/`、`README`、`CLAUDE.md`。

## 组成
- **docs-maintainer**（子 agent，model: sonnet）：承载全部文档维护逻辑。
- **/docs-update**（命令）：手动触发，主线程用 Task 派出 docs-maintainer。
- **PostToolUse hook**：在 `git commit`/`git push` 后注入非阻断提醒，建议派出 docs-maintainer。

## 工作机制
- 书签存于目标仓库 `.docs-assistant/state.json`，记录文档已覆盖到的 commit。每次只处理增量。
- 可选映射表 `.docs-assistant/docs-map.yaml`（"代码路径 → 关联文档"）加速定位；缺失时回退到全量判断。
- 文档改动直接写入工作区，由你 `git diff` 复查后自行提交；插件不替你提交。

## 安装
将本插件目录加入 Claude Code 插件路径（参见 Claude Code 插件文档）。

## 使用
- 手动：在目标仓库运行 `/docs-update`。
- 自动：正常 `git commit`/`git push`，hook 会提醒主线程派出 docs-maintainer。
- 首次在某仓库运行时，会询问是补齐历史文档还是从当前提交起算。

## 不做什么
- 不修改源码或其注释/docstring。
- 不阻断提交；不替代 `/init` 生成 CLAUDE.md。

## 开发
- 运行脚本单测：`bash tests/test-remind-docs.sh`
