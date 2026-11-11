#!/usr/bin/env bash
# dsh-desktop-ctl 安装脚本（Linux / Windows 自动分派）
#   Linux 用户级（无需 root）：./install.sh [--keybinding] [--agents] [--no-test] [--plugin]
#   Linux 系统级（需要 root）：sudo ./install.sh --system
#   Windows：在 Git Bash 里跑本脚本会自动转给 install.ps1；
#            或直接 powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${HOME}/.local/bin"
MODE=user
KEYBINDING=0
AGENTS=0
RUNTEST=1
SKIP_GSETTINGS=0
PLUGIN=0
USER_ARGS=()

die() { echo "错误: $*" >&2; exit 1; }
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

usage() {
  cat <<'EOF'
用法:
  ./install.sh                     装到 ~/.local/bin（推荐，无需 root）
  sudo ./install.sh --system       装系统依赖 + ydotoold 服务（会接着跑用户级安装）

选项:
  --dest DIR        安装目录，默认 ~/.local/bin
  --keybinding      把 Ctrl+PrintScreen 绑成 dctl 截图
  --agents          把桌面操控准则追加到 ~/.dsh/AGENTS.md（DSH 会读）
  --plugin          顺便把本目录注册成 DSH 插件（dsh plugin --profile desktop add link:...）
  --no-test         装完不跑自检
  --skip-gsettings  不改 gsettings（无障碍开关）
  -h, --help        看帮助
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --system) MODE=system; shift ;;
    --dest) DEST="$2"; shift 2 ;;
    --keybinding) KEYBINDING=1; USER_ARGS+=("--keybinding"); shift ;;
    --agents) AGENTS=1; USER_ARGS+=("--agents"); shift ;;
    --no-test) RUNTEST=0; USER_ARGS+=("--no-test"); shift ;;
    --skip-gsettings) SKIP_GSETTINGS=1; USER_ARGS+=("--skip-gsettings"); shift ;;
    --plugin) PLUGIN=1; USER_ARGS+=("--plugin"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- 平台分派
UNAME="$(uname -s 2>/dev/null || echo unknown)"
case "$UNAME" in
  MINGW*|MSYS*|CYGWIN*)
    # Windows：bash 只是外壳，真正干活的是 install.ps1
    say "检测到 Windows（$UNAME），转给 install.ps1"
    WIN_PS1="$(cygpath -w "$HERE/install.ps1" 2>/dev/null || echo "$HERE/install.ps1")"
    exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$WIN_PS1" "$@"
    ;;
  Darwin)
    die "macOS 暂未支持（没有 UI Automation / AT-SPI 的等价物）。本插件支持 Windows 与 Linux。"
    ;;
esac

# ---------------------------------------------------------------- 系统级
if [[ "$MODE" == system ]]; then
  [[ "$(id -u)" -eq 0 ]] || die "系统级安装需要 root：sudo $0 --system"
  say "安装系统依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  apt-get install -y --no-install-recommends \
    at-spi2-core python3-gi gir1.2-atspi-2.0 \
    ydotool wl-clipboard xclip zenity gsettings-desktop-schemas \
    || apt-get install -y at-spi2-core python3-gi gir1.2-atspi-2.0 ydotool wl-clipboard xclip zenity

  say "启用 uinput"
  modprobe uinput 2>/dev/null || true
  echo uinput > /etc/modules-load.d/uinput.conf

  say "写入 ydotoold 服务"
  cat > /etc/systemd/system/ydotoold.service <<'UNIT'
[Unit]
Description=ydotoold (ydotool daemon, desktop-ctl)
After=graphical.target

[Service]
Type=simple
ExecStart=/usr/bin/ydotoold --socket-path=/tmp/.ydotool_socket --socket-perm=0666
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now ydotoold.service
  sleep 0.5
  systemctl is-active --quiet ydotoold.service \
    && echo "ydotoold 已运行，套接字: $(ls -l /tmp/.ydotool_socket 2>/dev/null || echo 缺失)" \
    || die "ydotoold 没起来，看 journalctl -u ydotoold -n 30"

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
    say "接着做用户级安装（用户 ${SUDO_USER}）"
    su - "$SUDO_USER" -c "bash $(printf '%q ' "${HERE}/install.sh") ${USER_ARGS[*]:-}"
  else
    echo "提示: 现在用普通用户再跑一次 ./install.sh 完成用户级安装"
  fi
  exit 0
fi

# ---------------------------------------------------------------- 用户级
say "安装 dctl 到 ${DEST}"
mkdir -p "$DEST"
install -m 0755 "${HERE}/cli/linux/dctl" "${DEST}/dctl"
echo "已安装: ${DEST}/dctl"

case ":${PATH}:" in
  *":$DEST:"*) ;;
  *) echo "注意: ${DEST} 不在 PATH 里。加到 ~/.bashrc：
    export PATH=\"\$HOME/.local/bin:\$PATH\"   # 或直接用 ${DEST}/dctl" ;;
esac

if [[ "$SKIP_GSETTINGS" -eq 0 ]] && command -v gsettings >/dev/null 2>&1; then
  say "打开无障碍桥（toolkit-accessibility）"
  gsettings set org.gnome.desktop.interface toolkit-accessibility true && echo "已开启"
fi

if [[ "$KEYBINDING" -eq 1 ]]; then
  say "绑定 Ctrl+PrintScreen → dctl 截图"
  DCTL_ABS="${DEST}/dctl" /usr/bin/python3 - <<'PY'
import os, sys
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio

NS = "org.gnome.settings-daemon.plugins.media-keys"
CB = NS + ".custom-keybinding"
path = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/desktop-ctl-shot/"

media = Gio.Settings.new(NS)
cur = list(media.get_strv("custom-keybindings"))

# 先看这个组合是不是已经被别的自定义快捷键占了（别硬抢）
def norm(b):
    return b.replace("<Primary>", "<Control>").replace("<Ctrl>", "<Control>")

conflict = None
for p in cur:
    if p == path:
        continue
    kb = Gio.Settings.new_with_path(CB, p)
    if norm(kb.get_string("binding")) == "<Control>Print":
        conflict = (kb.get_string("name"), kb.get_string("command"), p)
        break

if conflict and path not in cur:
    name, cmd, p = conflict
    print("跳过：Ctrl+PrintScreen 已被占用")
    print("  占用者: %s  →  %s" % (name or "(未命名)", cmd or "(空)"))
    print("  想改指向 dctl 的话：")
    print("    gsettings set %s:%s command '%s shot'" % (CB, p, os.environ["DCTL_ABS"]))
    sys.exit(0)

if path not in cur:
    cur.append(path)
    media.set_strv("custom-keybindings", cur)

kb = Gio.Settings.new_with_path(CB, path)
kb.set_string("name", "全屏截图（dctl）")
kb.set_string("command", os.environ["DCTL_ABS"] + " shot")
kb.set_string("binding", "<Control>Print")
print("已绑定: Ctrl+PrintScreen → %s shot" % os.environ["DCTL_ABS"])
PY
fi

if [[ "$AGENTS" -eq 1 ]]; then
  say "把操控准则写进 ~/.dsh/AGENTS.md"
  mkdir -p "${HOME}/.dsh"
  SNIP="${HERE}/AGENTS-desktop-ctl.md"
  TARGET="${HOME}/.dsh/AGENTS.md"
  [[ -f "$SNIP" ]] || die "缺少 $SNIP"
  if [[ -f "$TARGET" ]] && grep -q "desktop-ctl:begin" "$TARGET" 2>/dev/null; then
    echo "已经写过（desktop-ctl:begin 标记存在），跳过"
  else
    { [[ -f "$TARGET" ]] && printf '\n\n'; cat "$SNIP"; } >> "$TARGET"
    echo "已追加到 $TARGET"
  fi
fi

if [[ -f "${HERE}/skill/desktop-control.md" ]] && [[ -d "${HOME}/.memory/skills" ]]; then
  cp "${HERE}/skill/desktop-control.md" "${HOME}/.memory/skills/desktop-control.md"
  echo "已复制记忆页到 ~/.memory/skills/desktop-control.md"
fi

if [[ "$PLUGIN" -eq 1 ]]; then
  say "注册成 DSH 插件"
  if command -v dsh >/dev/null 2>&1; then
    dsh plugin --profile "${DSH_PROFILE:-desktop}" add "link:$HERE" && echo "已注册；重启 DSH 后会出现 desktop 工具"
  else
    echo "没找到 dsh 命令。手动注册（在 DSH 自带终端里）:"
    echo "  dsh plugin --profile desktop add \"link:$HERE\""
  fi
fi

if [[ "$RUNTEST" -eq 1 ]]; then
  say "环境自检"
  "${DEST}/dctl" doctor || true
  say "端到端自检（会弹一个输入框，几秒后自动关闭）"
  if "${DEST}/dctl" selftest; then
    echo ""
    echo "装好了。接下来照着 TUTORIAL.md 用。"
  else
    echo ""
    echo "自检没过，看 TUTORIAL.md 的「排错」一节。"
    exit 1
  fi
fi
