# docs-assistant

维护项目文档的 Claude Code 插件。代码改动后，自动检查自"上次文档更新点"以来的提交，并同步更新 `docs/`、`README`、`CLAUDE.md`。

## 组成
- **docs-maintainer**（子 agent，model: sonnet）：承载全部文档维护逻辑。
- **/docs-update**（命令）：手动触发，主线程用 Task 派出 docs-maintainer。
- **PostToolUse hook**：在 `git commit`/`git push` 后注入非阻断提醒，建议派出 docs-maintainer。

## 工作机制
- 书签存于目标仓库 `.docs-assistant/state.json`，记录文档已覆盖到的 commit。每次只处理增量。
- 可选映射表 `.docs-assistant/docs-map.yaml`（"代码路径 → 关联文档"）加速定位；缺失时回退到全量判断。
- agent 改完文档后会**定向自动本地提交**（仅文档 + `.docs-assistant/`，绝不裹入你其它改动，也**不会 push**），保持工作区干净。你在 `git push` 前用 `git log` / `git show` 复查即可，不满意 `git reset` 回退。
- `.docs-assistant/state.json` 与 `docs-map.yaml` **应纳入版本管理**（不要 gitignore），否则新克隆会重新冷启动、团队无法共享书签。
- 书签只在"文档真有改动"时前移，稳态下通常落后 HEAD 一个文档提交，属正常。

## 快速开始

### 在 Claude Code 中安装（推荐）

本仓库本身就是一个 Claude Code 插件 marketplace，在 Claude Code 里直接两条命令即可安装：

```text
/plugin marketplace add meihao86/docs-assistant
/plugin install docs-assistant@docs-assistant
```

- 第一条：把本仓库注册为 marketplace（`meihao86/docs-assistant` 会从 GitHub 拉取）。
- 第二条：从该 marketplace 安装 `docs-assistant` 插件（格式为 `插件名@marketplace名`）。

安装后运行 `/reload-plugins` 或重启 Claude Code 使其生效。验证：

- `/docs-update` 命令可用（注意插件命令带命名空间，可能显示为 `/docs-assistant:docs-update`）；
- `/agents` 中能看到 `docs-maintainer`；
- 执行一次 `git commit` 后会收到"文档可能未同步"的提醒。

更新插件：`/plugin marketplace update docs-assistant`，再 `/plugin install docs-assistant@docs-assistant`。
卸载：`/plugin uninstall docs-assistant@docs-assistant`。

### 本地开发/试用（免安装）

克隆本仓库后，用 `--plugin-dir` 直接加载，改动后 `/reload-plugins` 即可热更新：

```bash
git clone https://github.com/meihao86/docs-assistant.git
claude --plugin-dir ./docs-assistant
```

## 使用
- 手动：在目标仓库运行 `/docs-update`（或 `/docs-assistant:docs-update`）。
- 自动：正常 `git commit`/`git push`，hook 会提醒主线程派出 docs-maintainer。
- 首次在某仓库运行时，会询问是补齐历史文档还是从当前提交起算。

## 不做什么
- 不修改源码或其注释/docstring。
- 不阻断提交；不替代 `/init` 生成 CLAUDE.md。

## 开发
- 运行脚本单测：`bash tests/test-remind-docs.sh`
