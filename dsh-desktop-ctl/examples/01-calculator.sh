#!/usr/bin/env bash
# 示例 1：全程无坐标地算 7+8，并用截图核对结果。
# 演示「找元素 → act 点击 → 截图看结果」这条主干。
set -euo pipefail

APP="计算器"          # 应用名或窗口标题都能匹配
DCTL="${DCTL:-dctl}"

# 1) 没开就先开，然后等它出现在无障碍树里
if ! "${DCTL}" windows | grep -q "${APP}"; then
  "${DCTL}" launch gnome-calculator
fi
"${DCTL}" wait --app "${APP}" --timeout 10

# 2) 按文字找按钮，拿 ref 再点
press() {
  local label="$1" ref
  ref="$("${DCTL}" find "${label}" --app "${APP}" --role button --depth 26 | head -1 | cut -d' ' -f1)"
  [[ -n "${ref}" ]] || { echo "找不到按钮：${label}" >&2; exit 1; }
  "${DCTL}" act "${ref}" >/dev/null
  sleep 0.25
}

press 7
press '+'
press 8
press '='

# 3) 结果用截图确认（GTK4 的显示区读不到文字，只能看）
echo "结果截图：$("${DCTL}" shot --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["path"])')"
