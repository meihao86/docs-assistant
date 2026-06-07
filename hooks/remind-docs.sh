#!/usr/bin/env bash
# docs-assistant: PostToolUse hook
# 在 git commit / git push 后，向主线程注入非阻断提醒，建议派出 docs-maintainer 更新文档。
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

# 仅匹配 git commit / git push
if ! grep -Eq '\bgit\b.*\b(commit|push)\b' <<<"$command"; then
  exit 0
fi

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
