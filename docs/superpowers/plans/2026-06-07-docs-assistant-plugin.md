# docs-assistant 插件实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现一个 Claude Code 插件 docs-assistant，包含一个 docs-maintainer 子 agent，在 git 提交后（或手动 /docs-update）检查自上次文档更新点以来的代码改动并同步更新 `docs/`、`README`、`CLAUDE.md`。

**Architecture:** 插件由五部分组成：(1) `agents/docs-maintainer.md` 子 agent，承载全部文档维护逻辑（读 git diff、查 docs-map、快速跳过判断、改文档、推进书签）；(2) `commands/docs-update.md` 手动触发命令，由主线程用 Task 派出该子 agent；(3) `hooks/` 一个 PostToolUse hook，在 git commit/push 后注入非阻断提醒；(4) `.claude-plugin/plugin.json` 清单与 `.claude-plugin/marketplace.json`（单仓库即 marketplace，支持 `/plugin marketplace add` 一键注册）；(5) `README.md` 与 `tests/test-remind-docs.sh`（脚本单测）。状态文件 `.docs-assistant/state.json` 与映射表 `.docs-assistant/docs-map.yaml` 写在被维护的目标仓库里，运行时由 agent 创建，不属于插件本体。

**Tech Stack:** Markdown（agent/command 定义）、JSON（plugin.json / hooks.json）、Bash + jq（hook 脚本与测试）。

**执行说明（给 DeepSeek）：** 本计划的可自动验证部分是文件创建、JSON 合法性、Bash 脚本单测（任务 2/3 用 `jq`、`bash` 即可跑）。Claude Code 内的端到端集成（插件加载、agent 派发）需在 Claude Code 中人工验证，见任务 7，DeepSeek 无需也无法执行该步，照原样保留清单即可。

**前置依赖：** 系统已安装 `jq`、`git`、`bash`。

---

## 文件结构

```
docs-assistant/
├── .claude-plugin/
│   ├── plugin.json              # 任务 1：插件清单
│   └── marketplace.json         # 单仓库即 marketplace 的发布源定义
├── agents/
│   └── docs-maintainer.md       # 任务 4：核心子 agent（model: sonnet）
├── commands/
│   └── docs-update.md           # 任务 5：/docs-update 手动触发
├── hooks/
│   ├── remind-docs.sh           # 任务 2：PostToolUse 提醒脚本
│   └── hooks.json               # 任务 3：hook 注册
├── tests/
│   └── test-remind-docs.sh      # 任务 2：脚本单测
├── .gitignore
├── README.md                    # 任务 6
└── docs/superpowers/...         # 已有：spec 与本计划
```

每个文件单一职责：脚本只做"识别 git commit/push 并产出提醒文本"；agent 承载全部业务判断；命令只负责派发与冷启动交互中转。

---

## Task 1: 插件清单 plugin.json

**Files:**
- Create: `.claude-plugin/plugin.json`

- [ ] **Step 1: 写清单文件**

```json
{
  "name": "docs-assistant",
  "version": "0.1.0",
  "description": "代码改动后自动维护文档：检查自上次更新点以来的提交，同步 docs/、README、CLAUDE.md。",
  "author": {
    "name": "meihao"
  }
}
```

- [ ] **Step 2: 校验 JSON 合法**

Run: `jq empty .claude-plugin/plugin.json && echo OK`
Expected: 输出 `OK`，无报错。

- [ ] **Step 3: 提交**

```bash
git add .claude-plugin/plugin.json
git commit -m "feat: 添加插件清单 plugin.json"
```

---

## Task 2: PostToolUse 提醒脚本 remind-docs.sh（TDD）

脚本职责：从 stdin 读 hook JSON，仅当 `tool_name=Bash` 且命令**真的在执行** `git commit`/`git push`（排除 `--help`）时，向 stdout 输出 `hookSpecificOutput.additionalContext` JSON，提醒主线程派出 docs-maintainer；其余情况无输出。始终 exit 0（PostToolUse 无法阻断）。

> 精确匹配：**不能用子串匹配**，否则命令文本里仅“提及” `git commit/push`（如 `grep`/`echo`/注释/`git log --grep=commit`）会误触发。做法是按 shell 分隔符（`;` `|` `&` 换行）拆段，逐段判断该段（去掉前导 env 赋值后）是否以 `git` 开头、且其子命令（跳过全局选项）为 `commit`/`push`。

**Files:**
- Create: `tests/test-remind-docs.sh`
- Create: `hooks/remind-docs.sh`

- [ ] **Step 1: 先写失败的测试**

创建 `tests/test-remind-docs.sh`：

```bash
#!/usr/bin/env bash
# docs-assistant: remind-docs.sh 单元测试
set -uo pipefail
HOOK="$(cd "$(dirname "$0")/.." && pwd)/hooks/remind-docs.sh"
pass=0; fail=0

run() { printf '%s' "$1" | bash "$HOOK"; }

assert_contains() { # desc input needle
  local out; out=$(run "$2")
  if grep -q "$3" <<<"$out"; then echo "PASS: $1"; pass=$((pass+1));
  else echo "FAIL: $1"; echo "  out: $out"; fail=$((fail+1)); fi
}

assert_empty() { # desc input
  local out; out=$(run "$2")
  if [[ -z "$out" ]]; then echo "PASS: $1"; pass=$((pass+1));
  else echo "FAIL: $1"; echo "  out: $out"; fail=$((fail+1)); fi
}

assert_valid_json() { # desc input
  local out; out=$(run "$2")
  if jq empty <<<"$out" 2>/dev/null; then echo "PASS: $1"; pass=$((pass+1));
  else echo "FAIL: $1"; echo "  out: $out"; fail=$((fail+1)); fi
}

assert_contains "git commit 触发提醒" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m hello"}}' \
  "docs-maintainer"

assert_valid_json "git commit 输出是合法 JSON" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit -m hello"}}'

assert_contains "git push 触发提醒" \
  '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}' \
  "docs-maintainer"

assert_empty "非 git 命令不触发" \
  '{"tool_name":"Bash","tool_input":{"command":"npm test"}}'

assert_empty "非 Bash 工具不触发" \
  '{"tool_name":"Write","tool_input":{"file_path":"a.txt"}}'

assert_empty "git commit --help 不触发" \
  '{"tool_name":"Bash","tool_input":{"command":"git commit --help"}}'

# —— 精确匹配：仅“真正执行” git commit/push 才触发，仅提及字样不触发 ——

assert_empty "echo 仅提及 git commit 不触发" \
  '{"tool_name":"Bash","tool_input":{"command":"echo \"记得 git commit\""}}'

assert_empty "grep 模式含 git push 不触发" \
  '{"tool_name":"Bash","tool_input":{"command":"grep -q \"git push\" notes.txt"}}'

assert_empty "git log --grep=commit 不触发（子命令是 log）" \
  '{"tool_name":"Bash","tool_input":{"command":"git log --grep=commit"}}'

assert_contains "复合命令 npm test && git commit 触发" \
  '{"tool_name":"Bash","tool_input":{"command":"npm test && git commit -m x"}}' \
  "docs-maintainer"

assert_contains "git -c 全局选项后 commit 触发" \
  '{"tool_name":"Bash","tool_input":{"command":"git -c user.name=x commit -m y"}}' \
  "docs-maintainer"

assert_contains "前导 env 赋值后 git push 触发" \
  '{"tool_name":"Bash","tool_input":{"command":"GIT_SSH_COMMAND=ssh git push origin main"}}' \
  "docs-maintainer"

echo "---"; echo "pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
```

- [ ] **Step 2: 运行测试，确认失败**

Run: `bash tests/test-remind-docs.sh`
Expected: FAIL（`hooks/remind-docs.sh` 尚不存在，所有用例报错/失败，最后退出码非 0）。

- [ ] **Step 3: 实现脚本**

创建 `hooks/remind-docs.sh`：

```bash
#!/usr/bin/env bash
# docs-assistant: PostToolUse hook
# 在“真正执行” git commit / git push 时，向主线程注入非阻断提醒，建议派出 docs-maintainer。
set -euo pipefail

input=$(cat)

tool_name=$(jq -r '.tool_name // empty' <<<"$input")
command=$(jq -r '.tool_input.command // empty' <<<"$input")

# 仅处理 Bash 工具
[[ "$tool_name" == "Bash" ]] || exit 0

# 排除 help/查询类
if grep -Eq -- '--help|(^| )-h( |$)' <<<"$command"; then
  exit 0
fi

# 判断命令是否“真的在执行” git commit / git push（避免子串误判）。
# 按 shell 分隔符拆段，逐段判断：该段（去前导 env 赋值后）是否以 git 开头、且子命令为 commit/push。
is_git_commit_or_push() {
  local normalized seg
  normalized=$(printf '%s' "$1" | tr ';|&\n' '\n\n\n\n')
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    while [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
      seg="${seg#*[[:space:]]}"
      seg="${seg#"${seg%%[![:space:]]*}"}"
    done
    [[ "$seg" == "git" || "$seg" == git\ * ]] || continue
    local toks i n t sub=""
    read -r -a toks <<<"$seg"
    n=${#toks[@]}; i=1
    while (( i < n )); do
      t="${toks[$i]}"
      case "$t" in
        -c|-C|--exec-path|--git-dir|--work-tree|--namespace) i=$((i + 2)); continue ;;
        -*) i=$((i + 1)); continue ;;
        *) sub="$t"; break ;;
      esac
    done
    [[ "$sub" == "commit" || "$sub" == "push" ]] && return 0
  done <<<"$normalized"
  return 1
}

is_git_commit_or_push "$command" || exit 0

read -r -d '' ctx <<'EOF' || true
[docs-assistant] 检测到刚执行了 git commit/push，文档可能未与代码同步。
建议用 Task 工具派出 docs-maintainer 子 agent 检查并更新文档（docs/、README、CLAUDE.md），或运行 /docs-update。
这是非阻断提醒，可按需忽略。
EOF

jq -n --arg ctx "$ctx" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  }
}'

exit 0
```

- [ ] **Step 4: 赋可执行权限并运行测试，确认通过**

Run: `chmod +x hooks/remind-docs.sh && bash tests/test-remind-docs.sh`
Expected: 全部 `PASS`，末行 `pass=12 fail=0`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add hooks/remind-docs.sh tests/test-remind-docs.sh
git commit -m "feat: 添加 PostToolUse 提醒脚本与单测"
```

---

## Task 3: hook 注册 hooks.json

**Files:**
- Create: `hooks/hooks.json`

- [ ] **Step 1: 写 hook 配置**

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/remind-docs.sh"
          }
        ]
      }
    ]
  }
}
```

- [ ] **Step 2: 校验 JSON 合法**

Run: `jq empty hooks/hooks.json && echo OK`
Expected: 输出 `OK`。

- [ ] **Step 3: 校验引用脚本存在且可执行**

Run: `test -x hooks/remind-docs.sh && echo OK`
Expected: 输出 `OK`。

- [ ] **Step 4: 提交**

```bash
git add hooks/hooks.json
git commit -m "feat: 注册 PostToolUse hook"
```

---

## Task 4: 核心子 agent docs-maintainer.md

这是插件的核心，承载全部文档维护逻辑。内容为给子 agent 的中文指令，需完整覆盖 spec 第 5 节工作流。

**Files:**
- Create: `agents/docs-maintainer.md`

- [ ] **Step 1: 写 agent 定义**

```markdown
---
name: docs-maintainer
description: 检查自上次文档更新点以来的代码改动，并同步更新 docs/、README、CLAUDE.md。git 提交后由主线程派出，或通过 /docs-update 手动触发。
model: sonnet
---

你是 docs-maintainer，负责让项目文档与代码保持同步。维护范围仅限：`docs/` 目录、各级 `README`、`CLAUDE.md`。**绝不修改源码或其注释/docstring。**

所有自然语言输出与文档内容用简体中文；变量名、API 字段、命令、路径等技术标识符保持英文。

## 状态与映射文件（位于目标仓库）
- 书签：`.docs-assistant/state.json`，格式：
  `{"last_documented_commit": "<sha>", "updated_at": "<iso8601>", "tracked_paths": ["docs/","README.md","CLAUDE.md"]}`
- 映射表（可选）：`.docs-assistant/docs-map.yaml`，"代码路径(glob) → 关联文档"。

## 执行流程

### 0. 前置：确保是 git 仓库
- 运行 `git rev-parse --is-inside-work-tree`。若不是 git 仓库，执行 `git init` 并告知用户（书签/增量机制依赖 git）。
- 若仓库无任何提交（`git rev-parse HEAD` 失败），说明没有可作基线的 HEAD：停下并请用户先建立首个 commit，然后再运行本 agent。

### 1. 读取书签
- 读取 `.docs-assistant/state.json`。

### 2. 冷启动（state.json 不存在）
- 这是首次运行，需要用户决定起点。**由于你是被派出的子 agent，不要擅自猜测**：直接结束并向主线程返回一个明确的决策请求，内容包含两个选项：
  - A) 补齐历史文档：从仓库首个提交开始全量梳理并补文档；
  - B) 从当前 HEAD 起算：仅记录基线，之后只维护增量。
- 正常情况下 `/docs-update` 命令已在主线程问过用户并把 A/B 选择写进任务，agent 据此直接执行，不再追问；仅当任务未给出选择时才返回决策请求。
- 同时检查：若仓库无 `CLAUDE.md`，提示用户可用内置 `/init` 生成。
- 拿到选择后：
  - 选 A：以首个提交为区间起点执行第 4 步及之后流程（按第 6 步定向提交）；
  - 选 B：把当前 HEAD 写入 state.json 作为基线，按第 6 步**定向提交该基线文件**，汇报"已建立基线，从下次改动起维护"。

### 3. 计算增量（state.json 存在）
- 读取 `last_documented_commit`，运行 `git diff --name-only <last_documented_commit>..HEAD` 得到改动文件清单，必要时用 `git diff <last_documented_commit>..HEAD` 看具体改动。
- **同时 `git status --porcelain` 检查工作区**：区间 diff 看不到未提交改动；若有未提交的源码改动（手动触发常见），一并纳入分析，或提示用户先提交。
- 若 `last_documented_commit == HEAD` 且工作区无相关改动：无新内容，直接汇报"文档已是最新"并结束。

### 4. 快速跳过判断（命中即结束）
若**全部**改动都属于以下"无需更新"情形，则立即汇报"无需更新文档"，**不写 state.json、不提交、不动书签**，然后结束：
- 纯内部重构，不改公开接口 / CLI / 配置 / 对外行为
- 测试文件（`test/`、`*_test.*`、`*.spec.*` 等）
- 格式化 / lint / import 排序 / 纯空白
- 注释拼写、变量重命名等不影响文档描述的改动
- 依赖版本微调且不改使用方式
- 构建产物、临时文件、被 `.gitignore` 的路径
- 改动仅发生在文档自身或 `.docs-assistant/`
- bug 修复但未改变文档所描述的行为

只要有任一改动属于以下"必须更新"，进入第 5 步：公开 API / 函数签名、CLI 命令或参数、配置项、环境变量、目录结构、安装/使用步骤、任何对外行为变化。

### 5. 更新文档
- **查映射表**：读取 `.docs-assistant/docs-map.yaml`（不存在则跳过）。对每个改动路径按 glob 匹配，命中条目 → 收集其关联文档作为更新候选。
- **兜底**：未命中映射表的改动路径（或无映射表）→ 自行读取 `tracked_paths` 下的文档，判断哪些受影响。
- 阅读相关代码改动与对应文档，**直接编辑**需要更新的文档，使其与当前代码一致。保持原文档风格与语言。
- **半自动补表**：若发现某"代码↔文档"关系不在映射表中，向 `.docs-assistant/docs-map.yaml` 追加一条（文件不存在则创建），并在汇报中说明新增了哪些条目。

### 6. 提交并推进书签（仅当第 5 步真的改了文档）
> 无需更新时（第 4 步跳过或文档已一致）**不写 state.json、不提交、不动书签**，否则自动提交会因书签提交自身又触发处理而死循环。
- 用 `date -Iseconds` 取**真实**时间戳，不要编造。
- 把 `.docs-assistant/state.json` 写为：`last_documented_commit` = 当前 `git rev-parse HEAD`，`updated_at` = 真实时间，保留/补全 `tracked_paths`（默认 `["docs/","README.md","CLAUDE.md"]`）。
- **定向提交**：`git add` 仅本次改动的文档 + `.docs-assistant/state.json` +（如有）`.docs-assistant/docs-map.yaml`，再 `git commit -m "docs: 同步文档（<简述>）"`；**绝不 `git add -A/-u`**，**不 `git push`**。

### 7. 汇报
向主线程返回：改了哪些文档及原因、是否新增 docs-map 条目、本次本地提交的 commit message 与 SHA、书签 SHA。提醒用户：改动已本地提交（未 push），push 前用 `git log`/`git show` 复查，不满意可 `git reset` 回退。

## 约束
- 只对文档与 `.docs-assistant/` 做**定向** `git commit`；不修改源码；**不 `git push`**。
- 无需更新时不写 state.json、不提交、不动书签（避免自动提交死循环）；书签只在文档真有改动时前移，落后 HEAD 属正常。
- 不阻断任何流程；映射表缺失或不全只是退化为全量判断，绝不报错中断。
```

- [ ] **Step 2: 校验 frontmatter 与结构**

Run: `head -5 agents/docs-maintainer.md`
Expected: 前 5 行包含 `name: docs-maintainer`、`model: sonnet`、`description:` 字段，且首行为 `---`。

Run: `grep -c "git rev-parse" agents/docs-maintainer.md`
Expected: 输出 `>= 2`（前置检查与书签推进都用到）。

- [ ] **Step 3: 提交**

```bash
git add agents/docs-maintainer.md
git commit -m "feat: 添加 docs-maintainer 子 agent"
```

---

## Task 5: 手动触发命令 docs-update.md

命令体是给主线程的指令：冷启动交互在主线程先完成，再**单次**用 Task 派出 docs-maintainer（不依赖 SendMessage 续接子 agent）。

**Files:**
- Create: `commands/docs-update.md`

- [ ] **Step 1: 写命令定义**

```markdown
---
description: 检查代码改动并同步更新文档（docs/、README、CLAUDE.md）
---

目标：派出 `docs-maintainer` 子 agent 检查自上次文档更新点以来的代码改动并更新文档。冷启动交互在主线程先完成，再一次性派 agent。

## 步骤
1. **判断是否冷启动**：检查目标仓库是否存在 `.docs-assistant/state.json`。
   - **不存在**：用 AskUserQuestion 让用户选起点（A 补齐历史 / B 从当前 HEAD 起算）；若缺 `CLAUDE.md` 提示用户可用 `/init`。拿到选择后用 Task 派出 docs-maintainer，并在任务里写明 A 还是 B。
   - **已存在**：直接用 Task 派出 docs-maintainer 跑增量。
2. **转达结果**：把子 agent 的汇报转达用户——改了哪些文档、是否新增 docs-map、本次本地提交的 commit message 与 SHA、书签 SHA；提醒用户改动已本地提交（未 push），push 前可 `git log`/`git show` 复查，不满意 `git reset` 回退。
```

- [ ] **Step 2: 校验结构**

Run: `head -3 commands/docs-update.md`
Expected: 首行 `---`，含 `description:` 字段。

Run: `grep -q "docs-maintainer" commands/docs-update.md && grep -q "AskUserQuestion" commands/docs-update.md && echo OK`
Expected: 输出 `OK`。

- [ ] **Step 3: 提交**

```bash
git add commands/docs-update.md
git commit -m "feat: 添加 /docs-update 手动触发命令"
```

---

## Task 6: README.md

**Files:**
- Create: `README.md`

- [ ] **Step 1: 写 README**

```markdown
# docs-assistant

维护项目文档的 Claude Code 插件。代码改动后，自动检查自"上次文档更新点"以来的提交，并同步更新 `docs/`、`README`、`CLAUDE.md`。

## 组成
- **docs-maintainer**（子 agent，model: sonnet）：承载全部文档维护逻辑。
- **/docs-update**（命令）：手动触发，主线程用 Task 派出 docs-maintainer。
- **PostToolUse hook**：在 `git commit`/`git push` 后注入非阻断提醒，建议派出 docs-maintainer。

## 工作机制
- 书签存于目标仓库 `.docs-assistant/state.json`，记录文档已覆盖到的 commit。每次只处理增量。
- 可选映射表 `.docs-assistant/docs-map.yaml`（"代码路径 → 关联文档"）加速定位；缺失时回退到全量判断。
- agent 改完文档后**定向自动本地提交**（仅文档 + `.docs-assistant/`，不裹入你其它改动，也**不 push**），保持工作区干净；push 前用 `git log`/`git show` 复查即可。
- `.docs-assistant/state.json` 与 `docs-map.yaml` **应纳入版本管理**（勿 gitignore）。
- 书签只在文档真有改动时前移，稳态下通常落后 HEAD 一个文档提交，属正常。

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
```

- [ ] **Step 2: 校验关键内容存在**

Run: `grep -q "docs-maintainer" README.md && grep -q ".docs-assistant/state.json" README.md && echo OK`
Expected: 输出 `OK`。

- [ ] **Step 3: 提交**

```bash
git add README.md
git commit -m "docs: 添加 README"
```

---

## Task 7: 端到端集成验证（在 Claude Code 中人工执行）

> DeepSeek 无法执行此任务，原样保留即可。供用户在 Claude Code 中验证。

- [ ] **Step 1: 加载插件**，确认 `/docs-update` 命令、`docs-maintainer` agent、PostToolUse hook 均被识别（如通过 `/hooks`、`/agents` 查看）。
- [ ] **Step 2: 冷启动**：在一个带改动历史的测试仓库运行 `/docs-update`，确认会询问"补齐历史 / 从当前起算"，并据选择写出 `.docs-assistant/state.json`。
- [ ] **Step 3: 增量更新**：改动某段会影响文档的代码并 commit，运行 `/docs-update`，确认相关文档被更新、书签推进、文档改动留在工作区待复查。
- [ ] **Step 4: 快速跳过**：仅改动测试文件后 commit，运行 `/docs-update`，确认汇报"无需更新文档"且书签仍推进。
- [ ] **Step 5: hook 提醒**：执行一次 `git commit`，确认主线程收到"文档可能未同步"的非阻断提醒、且 commit 未被阻断。

---

## 自检对照（spec 覆盖）

- 触发方式（手动 + hook）：任务 5、任务 2/3 ✔
- hook PostToolUse 不阻断：任务 2/3 ✔
- 书签独立文件 state.json：任务 4 第 1/6 步 ✔
- 文档范围 docs/README/CLAUDE.md：任务 4 ✔
- 冷启动问用户 + git init + 缺 CLAUDE.md 提示 /init：任务 4 第 0/2 步、任务 5 ✔
- docs-map 查表 + 兜底 + 半自动补表（一期核心）：任务 4 第 5 步 ✔
- 快速跳过判定清单：任务 4 第 4 步 ✔
- 直接改 + git diff 复查、不替用户提交：任务 4 第 7 步、README ✔
- agent 模型 Sonnet：任务 4 frontmatter ✔
