---
title: 桌面操控（dctl）：无障碍树 + 键鼠注入 + 截图
date: 2026-11-11
type: skill
salience: 1
last_access: 2026-11-11
tags: [desktop, windows, uia, atspi, ydotool, automation]
sources: []
summary: 用 dctl 操控任意 GUI：Windows 走 UI Automation、Linux 走 AT-SPI，按 ref 做元素级点击/写值，配键鼠注入与截图兜底；坐标点击只做兜底。
---

# 桌面操控：dctl

一个命令收进三层能力：**无障碍树**（Windows UI Automation / Linux AT-SPI；结构 + 元素级动作）、**键鼠注入**（Windows SendInput / Linux ydotool）、**截图**。

- 源码与文档：`dsh-desktop-ctl` 仓库（`cli/windows/dctl.ps1`、`cli/linux/dctl`）
- Windows 装到 `%LOCALAPPDATA%\dctl`，Linux 装到 `~/.local/bin/dctl`
- 同一条命令在两边语义一致，只在「键码、截图方式、输入可靠性」上有平台差异

## 主干用法

```bash
dctl doctor                       # 环境自检
dctl apps                         # 顶层窗口
dctl windows                      # 窗口 + 标题 + 所属进程
dctl tree 记事本 --depth 20        # 打整棵树（深度给够，按钮常常在第 10 层以下）
dctl find "确定" --app 记事本       # 找元素，返回 ref
dctl info <ref>                   # 名字/角色/动作/可写性/矩形
dctl act <ref>                    # 执行默认动作（按钮＝点击）
dctl set <ref> "中文也行"          # 直接写值（不需要焦点、不受输入法影响）
dctl read <ref>                   # 读文字
dctl key ctrl+s / key win         # 快捷键
dctl type "文本"                   # 往焦点打字（Windows 支持任意 Unicode）
dctl launch notepad --wait 10     # 启动并等窗口
dctl wait --app 记事本 --text 保存成功
dctl shot --json                  # 截图，拿路径后用 read_image 看
dctl geom                         # 坐标系体检（截图 ↔ 逻辑像素比例）
dctl selftest                     # 端到端自检：弹窗→写字→点确定→回读→截图
```

`ref` 是索引链：Windows 形如 `3/0/1`（从桌面根算起，绝对路径），Linux 是一条更长的链（如 `11/0/0/.../3`）。**每次重新 find，不要缓存 ref**。

## 决策顺序（重要）

1. 有树的界面 → `find` + `act`/`set`。零坐标、不抢焦点、支持中文。
2. 需要快捷键/菜单 → `dctl key`（Windows 一般不需要先 focus；Linux 上先 `dctl focus <ref>`）。
3. 要「看」结果 → `dctl shot --json` + read_image。**截图只用于阅读**，不当点击坐标系。
4. 没有树的界面（画布/游戏/远程桌面）→ 坐标兜底，必要时人工校准。
5. 网页/Electron 内容 → 走 Chrome 桥的 `browser_*`，不要坐标点。

## Windows 后端（dctl.ps1）的硬事实

- 只用系统自带组件：`UIAutomationClient` + `System.Drawing` + `SendInput`，**不需要管理员权限**，不装 Python/Node 依赖。
- 脚本必须带 **UTF-8 BOM**，否则 PowerShell 5.1 按 ANSI 解析，中文全乱；脚本内部还会设 `[Console]::OutputEncoding = UTF8`，让其他进程（node 插件）读回中文不乱码。
- `set` 优先 `ValuePattern.SetValue`；控件只读或没有 ValuePattern 时回退为「聚焦 + 剪贴板 + Ctrl+A/Ctrl+V」。
- `type` 走 `KEYEVENTF_UNICODE`，中文/emoji 都能打；只有代理对（部分 emoji）才回退剪贴板。
- 截图用 `Graphics.CopyFromScreen`，默认存 `%USERPROFILE%\Pictures\截图\`；多显示器用 `--monitor N`。
- 人手截全屏用系统自带的 **Win+PrtSc**（存 `图片\屏幕截图`），不需要额外绑定。
- 有 PowerShell 7 就跑 `pwsh`，没有就用自带的 5.1；`dctl.cmd` 会自动挑。

## Linux 后端（dctl，本机实测 2026-11-11 / Ubuntu 26.04 GNOME 50.1 Wayland）

- 会话：Wayland。`xdotool` 完全无效；输入走 ydotool（ydotoold 常驻，`YDOTOOL_SOCKET=/tmp/.ydotool_socket`）。
- **Space 键码是 57，不是 32**；截图路径 = `PrintScreen` → 等 2s → `Space`（GNOME 截图 UI 要空格确认保存）。
- 截图产物 640×360（整屏被缩放），逻辑分辨率 1920×1080；比例用 `dctl geom` 现算。
- AT-SPI **不报告窗口位置**：`SCREEN` 坐标恒为 (0,0)，只有 `WINDOW` 相对坐标可信 → 坐标点击不可靠。
- GTK4 应用（如 gnome-calculator）显示区 `read` 返回空 → 读值靠截图或应用自身回显。
- 应用名与窗口标题常不同步（计算器：应用 `gnome-calculator`、标题 `计算器`），dctl 两个都能匹配。
- 中文/emoji 只能走 `set`；`type`/`paste` 只对 ASCII 可靠。
- 同名窗口多开时 `--app` 只命中第一个（selftest 曾把字写进残留的旧窗口）→ 用 `--title` 区分。

## 已知失败路线（别再试）

- Linux：`gnome-screenshot -f`（Wayland 下报 X11 错）、`org.gnome.Shell.Screenshot`（AccessDenied）、portal Screenshot（弹交互框卡住）、`xdotool`。
- Windows：别用 pyautogui / 图像模板匹配猜坐标（DPI 缩放一变就废），也别用 MCP 子进程式的 computer-use 桥（启动慢、要额外二进制）。

## 相关页面

- [atspi-element-automation.md](atspi-element-automation.md) — 更早期的 a11y.py 做法与树结构细节
- [gnome-wayland-input-screenshot.md](gnome-wayland-input-screenshot.md) — ydotool/ydotoold 与截图脚本的来龙去脉
- [chrome-bridge-vs-native-automation.md](chrome-bridge-vs-native-automation.md) — 网页走桥、本机走 dctl 的分界
