#!/usr/bin/env bash
# 示例 2：填一个 zenity 表单并提交 —— 中文、不需要焦点、不需要坐标。
set -euo pipefail
DCTL="${DCTL:-dctl}"

out="$(mktemp)"
zenity --entry --title="登记" --text="你的名字：" >"${out}" &
pid=$!

"${DCTL}" wait --app 登记 --timeout 10

# 找那个输入框（role=text，是树里第一个可编辑的），直接写文字
ref="$("${DCTL}" find "" --app 登记 --role text --limit 1 | head -1 | cut -d' ' -f1)"
[[ -n "${ref}" ]] || { echo "找不到输入框" >&2; exit 1; }
"${DCTL}" set "${ref}" "沈叙 × 中文 ✓"

# 点「确定」
ok="$("${DCTL}" find "确定" --app 登记 --role button | head -1 | cut -d' ' -f1)"
"${DCTL}" act "${ok}" >/dev/null

wait "${pid}" || true
echo "对话框返回：$(cat "${out}")"
rm -f "${out}"
