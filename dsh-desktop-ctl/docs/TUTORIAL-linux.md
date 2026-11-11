# 用 DSH 完整操控一台 Linux 电脑：教程

> 目标：把「看界面 → 找控件 → 点/填 → 看结果」这条链路做成一台机器上可复制的能力。
> 成品是一个文件 `dctl` + 一个安装脚本。装完，agent 就能自己开应用、点按钮、填表单、按快捷键、截图确认。

---

## 0. 一句话原理

**主干用无障碍树（AT-SPI）做元素级操作，键鼠注入（ydotool）补快捷键和没有树的界面，截图只用来「看结果」。**

三段各司其职：

| 手段 | 干什么 | 为什么不替代别人 |
|---|---|---|
| AT-SPI 无障碍树 | 按角色/名字找到按钮、输入框，直接「执行点击动作」「写入文本」 | 不看坐标、不抢焦点、中英文都行；但没有树的界面（画布、部分自绘 UI）用不了 |
| ydotool 注入 | 真发按键/鼠标事件：`Ctrl+S`、`Alt+F4`、拖拽 | 精确但要求目标窗口有键盘焦点；只能可靠打 ASCII |
| 截图 | 确认结果、给视觉模型看、量尺寸 | 能看不能点：截图常被缩小，像素坐标 ≠ 屏幕坐标 |

把这三样按顺序用，就有了「完整操控」；反过来（先截图找坐标再点）在 Wayland + 高分屏上会一直点偏。

---

## 1. 目标机要求

- Linux + 图形会话（**GNOME 最优**；KDE/XFCE 也能用，截图和部分细节不同）
- Wayland 或 X11 都行（本文以 GNOME/Wayland 为准，X11 差异单独标出）
- 需要 root 一次（装系统包 + 起 ydotoold 服务）
- 不需要联网、不需要 API key、不需要 OCR

本教程的实测环境：Ubuntu 26.04 / GNOME Shell 50.1 / Wayland / 2560×1440@1.33 缩放 + HDR。

---

## 2. 安装（三步，约 3 分钟）

### 2.1 把包拷过去

```bash
# 打包（本机）
tar czf desktop-ctl.tar.gz desktop-ctl/
# 传到目标机（任选）
scp desktop-ctl.tar.gz 用户名@目标机:~
# 目标机解压
tar xzf desktop-ctl.tar.gz && cd desktop-ctl
```

### 2.2 系统层（要 root，一次就好）

```bash
sudo ./install.sh --system
```

它做四件事：

1. 装 `at-spi2-core python3-gi gir1.2-atspi-2.0 ydotool wl-clipboard xclip zenity`
2. 加载 `uinput` 内核模块（ydotool 往这里写事件）
3. 写 `/etc/systemd/system/ydotoold.service`，套接字 `/tmp/.ydotool_socket` 权限 0666
4. `systemctl enable --now ydotoold`，并自动接着跑用户级安装

> 为什么要常驻的 ydotoold：`ydotool` 只是客户端，真正写 `/dev/uinput` 的是守护进程。手动 `ydotool` 会报 *failed to connect socket /run/user/1000/.ydotool_socket* —— 那是没设 `YDOTOOL_SOCKET`，不是没权限。

### 2.3 用户层

```bash
./install.sh --keybinding --agents
```

- 把 `dctl` 装到 `~/.local/bin`
- `gsettings set org.gnome.desktop.interface toolkit-accessibility true`（**不开这个，无障碍树是空的**）
- `--keybinding`：把 `Ctrl+PrintScreen` 绑成 `dctl shot`（可选，但很好用）
- `--agents`：把操控准则追加到 `~/.dsh/AGENTS.md`（**最关键的一步，见第 3 节**）

### 2.4 验证

```bash
dctl doctor      # 逐项体检，全 OK 才能干活
dctl selftest    # 全链路：开输入框 → 写中文 → 点确定 → 截图
```

`selftest` 会闪一个 zenity 窗口，2 秒后自动关闭（开头会先清掉上次残留的同名窗口，避免把字写进别人的输入框），输出大致是：

```
1) 启动 zenity 输入框
2) 找到输入框 10/0/0/0/0/1/0/0/0/1
3) 已写入文本（无需键盘焦点）
4) 已点击确定
5) 回读正确：'沈叙 selftest ✓ 中文'
6) 截图 OK：/home/u/图片/截图/截图 2026-11-11 21-28-34.png  640x360
自检通过：元素级操作 + 键鼠 + 截图 全链路可用。
```

到了这一步，工具就能用了。下面是「让 agent 会用」。

---

## 3. 让 DSH 知道该用 dctl（别跳过）

工具装好≠agent 会用。模型默认会去试 `xdotool`、`gnome-screenshot`、portal 截图，然后全部失败，浪费十几轮。

`./install.sh --agents` 已把 `AGENTS-desktop-ctl.md` 追加进 `~/.dsh/AGENTS.md`（幂等，带 `<!-- desktop-ctl:begin -->` 标记）。它规定：

- 顺序：`dctl apps → tree → find → act/set → shot`
- 中文只走 `dctl set`，不走 `type/paste`
- 禁用 xdotool / gnome-screenshot / portal 截图
- 截图只用来「看」，不当坐标用
- 网页走 `browser_*` 调试桥

如果目标机的 DSH 用的不是 `~/.dsh/AGENTS.md`（比如工作区级），把那一段拷到对应位置即可。**没有 DSH 也能用**：`dctl` 是普通 CLI，人在终端里敲同样有效。

---

## 4. 日常配方

### 4.1 打开应用并确认它起来了

```bash
dctl launch gnome-calculator
dctl wait --app 计算器 --timeout 10
```

`launch` 支持 `.desktop`（走 `gtk-launch`，能正确激活已运行实例）和任意命令。

### 4.2 点按钮

```bash
dctl find "确定" --app zenity          # → 10/0/0/0/1/1  [button] name='确定(O)' actions=['click']
dctl act 10/0/0/0/1/1                  # 默认点 click
```

按钮文字常带快捷键后缀（`确定(O)`），`find` 是**子串匹配**，所以查 `确定` 就够了。

> **同名窗口多开时**（同时开了好几个 zenity / 好几个终端），`--app` 只会命中第一个。
> 用 `dctl windows` 看窗口标题，再加 `--title` 筛一层：
>
> ```bash
> dctl windows                                # 0/0  终端  用户@主机: ~/code
> dctl find "保存" --app 终端 --title code     # 只在标题含 code 的那个窗口里找
> ```
> 更省事的做法：先关掉没用的旧窗口，别让自动化选错对象。

### 4.3 填表单（含中文）

```bash
dctl find "名称" --app 某应用 --role text   # 找到输入框
dctl set <ref> "沈叙 测试 ✓"                 # 直接写入，不需要键盘焦点
```

`set` 走的是可编辑文本组件的 API，等同于「文本框里已有的内容被替换」。写长句、中文、符号都行。

### 4.4 读界面

```bash
dctl read <ref>        # 读文本/数值
dctl info <ref>        # 角色、名字、描述、可用动作
dctl tree 某应用 --depth 20 --roles button,text
```

注意：**GTK4 的输入框读回可能是空串**（组件不回传文本）。要确认内容，看目标应用自己的反馈（比如点确定后弹窗/退出码），或截图。

### 4.5 快捷键

```bash
dctl key ctrl+s
dctl key super            # 打开概览
dctl key alt+f4
dctl key ctrl+shift+t --times 3
```

键码表内置（`Space=57 PrintScreen=99 Super=125 Ctrl=29 Alt=56 Enter=28 F4=62`）。注意 Space 是 **57**，不是 ASCII 的 32——这个坑很常见。

### 4.6 一键全屏截图：Ctrl+PrintScreen

装的时候加 `--keybinding`，就会把 **Ctrl+PrintScreen** 绑成 `dctl shot`，等于「按一下就存一张全屏图」：

- **人按**：Ctrl+PrintScreen → 屏幕闪一下（GNOME 的截图 UI 自动确认）→ 新文件落在 `~/图片/截图/`
- **agent 按**：`dctl key ctrl+print` 等价；不过 agent 一般直接 `dctl shot` 更快，不用先抢焦点
- **拿路径**：`dctl shot --json` 回 `{"path":…,"width":640,"height":360}`；只想要最新一张：`ls -t ~/图片/截图/*.png | head -1`

实测（2026-11-11 本机）：`dctl key ctrl+print` 后 3 秒内出现 `截图 2026-11-11 21-40-34.png`，**640×360**（整屏内容被缩放，不是裁剪）。文件名带时间戳，不会互相覆盖。

> 如果这台机器已经把 Ctrl+PrintScreen 占了（自定义快捷键里已经有这个组合），安装脚本**不会硬加**，而是告诉你被谁占着，并给出改指向的命令。别让两个快捷键抢同一个组合。

### 4.7 看结果

```bash
dctl shot                 # 打印路径
dctl shot --json          # {"path": "...", "width": 640, "height": 360, "bytes": 29069}
```

然后把图片交给视觉模型看。本机截图是 640×360（见第 5 节），够看布局，看不清小字。

### 4.8 兜底：坐标点击

只有「没有无障碍树的界面」才用（游戏、画布、远程桌面）。见第 5 节的校准法。

```bash
dctl move 960 540
dctl click 960 540
```

---

## 5. 坐标系与截图：唯一的坑区

一台机器上常常有**四套数字**，别硬编码：

| 空间 | 本机实测 | 谁在用 |
|---|---|---|
| 物理模式 | 2560×1440 | DisplayConfig 的 mode |
| 逻辑分辨率 | 1920×1080 | 指针注入（ydotool 绝对坐标）、AT-SPI 窗口尺寸 |
| Xwayland 屏幕 | 3840×2160 | `xrandr`（开了原生缩放就是物理×1.5） |
| 截图 | 640×360 | GNOME 截图文件（HDR/缩放会缩到 1/4） |

查看：

```bash
dctl geom
```

```
会话: wayland / ubuntu:GNOME
显示器: 模式 2560x1440 @ (0,0) 缩放 1.3333 → 逻辑分辨率 1920x1080
X11 屏幕: 3840x2160
最近截图: .../截图 2026-11-11 21-28-46.png  640x360
截图→X11 比例: 6.000
截图→逻辑分辨率 比例: 3.000
```

**规矩：**

1. 元素级操作只用 `ref`，不碰坐标 —— 90% 的活到这就够了。
2. 需要坐标时，**先量后点**：截图里量出像素 × `截图→逻辑` 比例 = 逻辑坐标。
3. 第一次用坐标前做一次校准（下面）。
4. 截图变小是 GNOME 在 HDR/分数缩放下的行为；要精确像素就临时关 HDR，或换 wlroots 桌面用 `grim`。

**坐标校准（2 分钟）：**

```bash
# 1. 打开一个你认识的、有明确反馈的窗口（计算器最好）
dctl launch gnome-calculator && dctl wait --app 计算器
# 2. 截图，量出按钮「7」中心的像素 (px, py)
dctl shot --json
# 3. 换算：逻辑 = 像素 × (1919/639)  ← 用 dctl geom 给出的比例
# 4. 点它，再截图看计算器上有没有出现 7
dctl click <逻辑x> <逻辑y>; dctl shot --json
# 5. 没反应就把坐标 ×1.5 或 ×2 再试一次，命中的那个倍数记到配置里：
echo '{"pointer_scale": 2.0}' > ~/.config/dctl/config.json
```

> 为什么这么麻烦：GNOME/Wayland **不把窗口位置告诉 agent**。AT-SPI 里 frame 的坐标恒为 `(0,0)`，`dctl click --ref` 因此只能当兜底，别指望它。

---

## 6. 排错表

| 症状 | 原因 | 修法 |
|---|---|---|
| `dctl apps` 空的 / 只有 shell | 无障碍桥没开 | `gsettings set org.gnome.desktop.interface toolkit-accessibility true`，然后重启目标应用 |
| `dctl find` 找不到按钮 | 树深不够 / 文字不符 | `dctl tree 应用 --depth 24`；用子串而非全名（`确定(O)`） |
| `set` 报「不可编辑」 | 找错节点（label 不是 text） | `dctl info <ref>` 看角色，找 `[text]` 或 `[entry]` |
| 写入成功但应用没反应 | 应用需要触发 `activate`/需要提交 | `dctl act <ref> --action activate` 或再点「确定」 |
| 键盘操作没效果 | 新窗口没拿到焦点（GNOME 防抢焦点） | 先 `dctl focus <ref>`；或改用元素级操作（不需要焦点） |
| `ydotool` 报连不上 socket | `YDOTOOL_SOCKET` 没设 | `export YDOTOOL_SOCKET=/tmp/.ydotool_socket`；确认 `systemctl status ydotoold` |
| 截图超时 | 截图界面弹得慢 / 快捷键被改 | 先手动按 `PrintScreen` 再按空格试一次；`DCTL_SHOT_SETTLE=3 dctl shot` |
| 截图只有 640×360 | HDR/分数缩放下 GNOME 的行为 | 正常；要么接受，要么关 HDR |
| 点坐标永远点偏 | 用了截图像素当坐标 | 乘比例；见第 5 节校准 |
| Chrome 里查不到网页元素 | Chromium 默认关无障碍 | 启动加 `--force-renderer-accessibility`；或直接用 `browser_*` 桥 |
| `wl-paste` 卡住 | 本会话拿不到 Wayland 数据源 | 用 `xclip`（`dctl clip` 已优先 xclip 兜底） |

---

## 7. 平台差异

- **X11**：截图走 `gnome-screenshot -f`（`dctl` 自动选）；窗口坐标更可信，`click --ref` 通常能用。
- **KDE**：截图走 `spectacle -b -n -f`；无障碍树同样可用（AT-SPI 是跨桌面标准）。
- **wlroots（Sway/Hyprland）**：`grim` 直接截图，尺寸=物理像素，坐标最省事；键鼠用 `ydotool` 或 `wtype`。
- **无桌面（纯 X）**：这套用不上，直接用 xdotool。

---

## 8. 迁移与卸载

```bash
# 卸载（用户级）
rm -f ~/.local/bin/dctl
gsettings set org.gnome.desktop.interface toolkit-accessibility false   # 可选
# 卸载（系统级）
sudo systemctl disable --now ydotoold && sudo rm /etc/systemd/system/ydotoold.service
sudo apt remove ydotool   # 其余包多为桌面自带，别乱删
```

---

## 9. 附录：ref 是什么

`ref` 是「从桌面根到元素的索引链」，形如 `10/0/0/0/1/1`：

```
10          第 11 个顶层应用（dctl apps 里的序号）
0           它的第 1 个子节点（通常是窗口 frame）
0/0/1/1     往下逐层索引
```

**ref 只在界面结构不变时有效**。应用换了界面/重开窗口就重新 `find`。所以脚本里正确的写法是「先查再点」，而不是把 ref 写死。

---

## 10. 一句话总结

> 能用无障碍树就用无障碍树（稳、准、不看坐标）；
> 需要快捷键和拖动时用 ydotool（记得先给焦点）；
> 要确认结果或给视觉模型看时截图（记住它可能被缩小）。
> 坐标点击只在你确认没有树的时候用，而且要先校准。
