# dsh-desktop-ctl

给 [DSH](https://github.com/deepseek-ai) 的一个插件：**一个 `desktop` 工具，让 agent 真正会操作图形界面。**

它把「无障碍树找元素 → 元素级动作 → 键鼠注入 → 截图」四层收进一条命令 `dctl`，Windows 和 Linux 共用同一套动词：

- **Windows** → UI Automation（`UIAutomationClient`）+ `SendInput` + GDI 截图，只用系统自带组件，**不需要管理员权限、不装 Python/Node 依赖**
- **Linux** → AT-SPI 无障碍树 + ydotool（uinput）+ PrintScreen 截图，Wayland 下可用

```console
$ dctl apps                                   # 有哪些窗口
$ dctl find "确定" --app 记事本                 # 按钮在哪 → ref
$ dctl act 3/0/1/2                            # 点它（不用坐标、不抢焦点）
$ dctl set 3/0/1/1 "沈叙 中文也行"              # 写输入框（绕过输入法）
$ dctl key ctrl+s                             # 快捷键
$ dctl shot --json                            # 截图，拿路径再看
5	notepad	无标题 - 记事本
3/0/1/1	Edit	(输入区)
{"path":"C:\\Users\\you\\Pictures\\截图\\dctl 2026-11-11 22-03-11.png","width":2560,"height":1440}
```

## 为什么不是「截图 + 坐标点击」

| | 截图/坐标方案 | 本插件（无障碍树） |
|---|---|---|
| 定位 | 像素匹配，DPI 一缩放就废 | 元素的角色 + 名字，稳定 |
| 速度 | 每步都要截一张图、送模型看 | 一次 `find` 拿文本结果，几十毫秒 |
| 鲁棒 | 窗口被遮挡就失败 | 不需要可见，不抢焦点 |
| 中文/emoji | 拼音输入法打不出来 | `set` 直接写值，Windows 的 `type` 走 Unicode |
| 依赖 | 额外的 computer-use 服务/二进制 | Windows 零依赖；Linux 只要 ydotool |

坐标点击仍然保留（`dctl click x y`），但只用于画布、游戏、远程桌面这种没有无障碍树的界面。

## 安装

### Windows（推荐，2 分钟）

```powershell
git clone https://github.com/lofter5/dsh-desktop-ctl.git
cd dsh-desktop-ctl
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

安装脚本做四件事：复制到 `%LOCALAPPDATA%\dctl`、加进用户 PATH、把操控准则写进 `%USERPROFILE%\.dsh\AGENTS.md`、复制技能页到 `%USERPROFILE%\.memory\skills\`；最后跑 `doctor` 与 `selftest` 自检。

不想动 PATH / 不想跑自检：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Dest D:\tools\dctl -NoPath -SkipTest
```

### Linux（GNOME/Wayland 已实测；X11 也能用）

```bash
git clone https://github.com/lofter5/dsh-desktop-ctl.git
cd dsh-desktop-ctl
./install.sh --keybinding --agents      # 用户级，无需 root
sudo ./install.sh --system              # 只在需要装 ydotool 时跑（会接着做用户级安装）
```

### 装成 DSH 插件（让 agent 自己会调）

```powershell
# 从 GitHub 直接装（DSH 自带的 CLI）
dsh plugin --profile desktop add github:lofter5/dsh-desktop-ctl

# 或者从本地目录装（开发/改代码时用）
dsh plugin --profile desktop add "link:$PWD"
```

装完重启 DSH，宿主会多出一个 `desktop` 工具，参数就是 dctl 的命令行参数：

```json
desktop({"argv":["find","确定","--app","记事本"]})
```

不想装插件也行：`install.ps1` / `./install.sh --agents` 会把准则写进 AGENTS.md，agent 直接用 shell 调 `dctl` 效果一样，只是少了个结构化入口。

## 用法速查

| 想干什么 | 命令 |
|---|---|
| 有哪些窗口 | `dctl apps` / `dctl windows` |
| 看界面结构 | `dctl tree 记事本 --depth 20` |
| 找元素 | `dctl find "确定" --app 记事本 [--role Button]` |
| 点按钮 | `dctl act <ref>` |
| 写输入框 | `dctl set <ref> "文本"` |
| 读文字 | `dctl read <ref>` |
| 快捷键 | `dctl key ctrl+s` / `dctl key alt+f4` / `dctl key win` |
| 打字 | `dctl type "文本"` |
| 启动/等待 | `dctl launch notepad --wait 10`、`dctl wait --app X --text Y` |
| 截图 | `dctl shot --json`（人手：Windows `Win+PrtSc`，Linux `Ctrl+PrintScreen`） |
| 体检 | `dctl doctor` / `dctl geom` / `dctl selftest` |

完整教程：[`docs/TUTORIAL-windows.md`](docs/TUTORIAL-windows.md)、[`docs/TUTORIAL-linux.md`](docs/TUTORIAL-linux.md)。

## 两个平台差在哪

| | Windows | Linux |
|---|---|---|
| 树 | UI Automation | AT-SPI（需 `toolkit-accessibility=true`） |
| ref 形状 | `3/0/1`（桌面根算起的绝对路径） | `11/0/0/0/.../3`（更长） |
| 键鼠 | `SendInput`/`mouse_event` | ydotool（ydotoold 常驻） |
| 截图 | GDI `CopyFromScreen`，原生分辨率 | PrintScreen+Space，产物被缩放到 640×360 |
| 中文输入 | `set` 和 `type` 都可靠 | 只有 `set` 可靠（`type` 仅 ASCII） |
| 权限 | 普通用户即可（个别提权窗口除外） | 需要 ydotoold 常驻；改无障碍开关需用户设置 |

## 仓库结构

```text
cli/windows/dctl.ps1    Windows 后端（UIA + SendInput + GDI）
cli/windows/dctl.cmd    命令行入口（自动挑 powershell.exe / pwsh）
cli/linux/dctl          Linux 后端（AT-SPI + ydotool）
lib/index.js            DSH 插件：注册 desktop 工具 + 用法提示注入
cordis.patch.yml        插件挂载补丁
install.ps1              Windows 安装
install.sh               Linux 安装 / Windows 转派
docs/                    教程（Windows / Linux）
examples/                可直接跑的示例（bash / ps1）
skill/                  给 agent 的技能页（markdown）
```

## 已知限制

- 需要目标应用**暴露无障碍信息**。绝大多数 Win32/UWP/WPF/Electron（开无障碍后）与 GTK/Qt 应用都行；自绘 UI、游戏、远程桌面画面不行 → 退回坐标点击。
- Windows 提权窗口（UAC 对话框、以管理员身份运行的程序）在普通权限进程里看不到 → 需要以同样权限启动 dctl。
- Linux 上 GTK4 应用的部分显示区不暴露文本（读值靠截图）；Chromium/Electron 需要 `--force-renderer-accessibility`。
- 不做 OCR、不做图像匹配、不内置模型——它只负责「把界面变成可点的结构」。

## 发布到 GitHub（维护者）

```bash
git init -b main && git add -A && git commit -m "feat: dsh-desktop-ctl v2.0.0"
# 先在 GitHub 建空仓库，再：
git remote add origin git@github.com:lofter5/dsh-desktop-ctl.git
git push -u origin main
```

仓库地址已指向 lofter5；若改了用户名或 fork 到别处，记得同步 package.json 的 repository/homepage/bugs 与本文件里的链接。

## 许可

MIT
