#!/usr/bin/env bash
# 示例 3：截图并打印路径。加 --show 直接弹出来看。
set -euo pipefail
DCTL="${DCTL:-dctl}"

json="$("${DCTL}" shot --json)"
path="$(printf '%s' "${json}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')"
printf '%s\n' "${path}"

if [[ "${1:-}" == "--show" ]]; then
  xdg-open "${path}" >/dev/null 2>&1 &
fi
