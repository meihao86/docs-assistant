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

# 判断命令是否“真的在执行” git commit / git push。
# 不能用子串匹配：那会把仅在引号/grep 模式/echo 里出现 "git commit/push" 字样的命令误判。
# 做法：按常见 shell 分隔符（; | & 换行）拆成片段，逐段判断——
#   该片段（去掉前导 env 赋值后）是否以 git 开头，且其子命令（跳过全局选项）为 commit/push。
is_git_commit_or_push() {
  local normalized seg
  normalized=$(printf '%s' "$1" | tr ';|&\n' '\n\n\n\n')
  while IFS= read -r seg; do
    # 去前导空白
    seg="${seg#"${seg%%[![:space:]]*}"}"
    # 跳过前导环境变量赋值，如 GIT_AUTHOR_NAME=x git commit
    while [[ "$seg" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+ ]]; do
      seg="${seg#*[[:space:]]}"
      seg="${seg#"${seg%%[![:space:]]*}"}"
    done
    # 该片段必须以 git 作为命令
    [[ "$seg" == "git" || "$seg" == git\ * ]] || continue
    # 取 git 之后第一个非选项 token 作为子命令；跳过带参数的全局选项
    local toks i n t sub=""
    read -r -a toks <<<"$seg"
    n=${#toks[@]}
    i=1
    while (( i < n )); do
      t="${toks[$i]}"
      case "$t" in
        -c|-C|--exec-path|--git-dir|--work-tree|--namespace)
          i=$((i + 2)); continue ;;     # 这些全局选项各带一个参数
        -*)
          i=$((i + 1)); continue ;;     # 其它选项
        *)
          sub="$t"; break ;;
      esac
    done
    if [[ "$sub" == "commit" || "$sub" == "push" ]]; then
      return 0
    fi
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
