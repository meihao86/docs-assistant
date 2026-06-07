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
