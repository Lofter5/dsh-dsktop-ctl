# 在 Windows 上给 DSH 装「桌面操控」——完整教程

> 目标：装完之后，DSH 里的 agent 能自己找到窗口、点按钮、填表单、按快捷键、截图，而不是靠猜坐标。
> 工具叫 `dctl`，Windows 与 Linux 同一套动词；本教程只讲 Windows，Linux 见 [`TUTORIAL-linux.md`](`TUTORIAL-linux.md`)。

## 0. 装完你能做什么

```text
你: 把记事本打开，写「测试 123」，然后截图给我看
agent: dctl launch notepad --wait 10
       dctl find "" --app notepad --role Edit       → ref 3/0/1/1
       dctl set 3/0/1/1 "测试 123"
       dctl read 3/0/1/1                          → 测试 123
       dctl shot --json                           → C:\Users\you\Pictures\截图\dctl ....png
```

全程没有坐标、没有像素匹配、没有把截图丢给模型去「看哪里能点」。

## 1. 原理：三层，各管一段

| 层 | Windows 实现 | 管什么 | 什么时候用 |
|---|---|---|---|
| 结构（首选） | UI Automation（`UIAutomationClient`） | 把界面读成树：窗口 → 面板 → 按钮/输入框，每个节点有名字、角色、可用动作 | `apps / tree / find / info / read / act / set` |
| 键鼠（次选） | `SendInput` / `mouse_event` | 真按键、真点击，发送到当前焦点/指定坐标 | `key / type / click / move / focus` |
| 画面（只读） | GDI `CopyFromScreen` | 截屏成 PNG，给人或模型「看结果」 | `shot` |

三条顺序不能反：**能用树就用树**（不用坐标、不抢焦点、支持中文），树里没有的东西才动键鼠，截图只用来确认结果。

## 2. 目标机要求

- Windows 10 1809+ / Windows 11（需要自带 PowerShell 5.1，系统都自带；装了 PowerShell 7 更好，`dctl.cmd` 会自动挑）
- DSH 桌面版（任何自带 CLI 的版本；只有 GUI 也行，见 §5）
- **不需要**：管理员权限、Python、Node.js、额外的 computer-use 服务或 MCP 二进制
- 需要知道你的 DSH 用哪个 profile（默认 `desktop`；不确定就跑 `dsh plugin --help` 看）

## 3. 安装

### 3.1 拿到文件

```powershell
git clone https://github.com/lofter5/dsh-desktop-ctl.git
cd dsh-desktop-ctl
```

没有 git？下载仓库 zip 解压也行（保持目录结构，`install.ps1` 靠相对路径找 `cli\windows\dctl.ps1`）。

### 3.2 跑安装脚本

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

它会依次做：

1. 复制 `dctl.ps1` / `dctl.cmd` 到 `%LOCALAPPDATA%\dctl`（可用 `-Dest` 改）
2. 把这个目录加进**用户** PATH（不改系统 PATH，不用管理员）
3. 把「桌面操控准则」追加到 `%USERPROFILE%\.dsh\AGENTS.md`（DSH 每个会话都会读，agent 于是知道有 `dctl` 这件事）
4. 把技能页复制到 `%USERPROFILE%\.memory\skills\desktop-control.md`（装了 dsh-memory 的话，agent 还能按需查到细节）
5. 跑 `doctor`（环境体检）+ `selftest`（端到端：自己弹一个记事本 → 写中文 → 回读 → 截图 → 关掉）

常见选项：

```text
-Dest D:\tools\dctl    装到别处
-NoPath                 不动 PATH（只用绝对路径调）
-SkipTest               不跑 selftest（CI / 远程桌面里有用）
-SkipAgents             不写 AGENTS.md
-Plugin                 顺便注册成 DSH 插件（等价于 §5.1）
```

### 3.3 方式 B：只装成插件（不改 PATH）

如果你的 DSH 有完整 CLI，可以直接把仓库注册成插件——插件内部自己会用包里的 `cli\windows\dctl.ps1`，不需要全局命令：

```powershell
dsh plugin --profile desktop add "link:C:\path\to\dsh-desktop-ctl"
```

从 GitHub 装（发布之后）：

```powershell
dsh plugin --profile desktop add github:lofter5/dsh-desktop-ctl
```

### 3.4 方式 C：手工（不想跑脚本）

```powershell
# 1) 复制两个文件
mkdir "$env:LOCALAPPDATA\dctl"
copy cli\windows\dctl.ps1 "$env:LOCALAPPDATA\dctl\"
copy cli\windows\dctl.cmd "$env:LOCALAPPDATA\dctl\"

# 2) 加进用户 PATH（当前会话临时生效）
$env:Path += ";$env:LOCALAPPDATA\dctl"

# 3) 验证
dctl doctor
```

## 4. 五分钟验证

新开一个终端（让 PATH 生效），逐条敲，对照期望：

```powershell
dctl version        # → dctl 2.0.0 (windows)
dctl doctor         # 每行都应是 OK：系统 / PowerShell / UIA / 截图目录 / DPI
dctl apps           # 列出当前窗口：ref、进程、标题
dctl shot --json    # → {"path": "...png", "width": 2560, "height": 1440}
dctl selftest       # 自己开记事本、写中文、回读、截图、关窗，最后打印 OK
```

如果 `selftest` 通过，说明「找元素 → 写值 → 回读 → 截图」整条链路是通的，可以去 §5 接进 DSH 了。

## 5. 让 DSH 真正会用

### 5.1 注册成插件（推荐）

```powershell
dsh plugin --profile desktop add "link:$PWD"
# 重启 DSH
```

重启后，宿主多一个 `desktop` 工具，参数就是 dctl 的命令行参数数组：

```json
desktop({ "argv": ["apps"] })
desktop({ "argv": ["find", "确定", "--app", "记事本"] })
desktop({ "argv": ["act", "3/0/1/2"] })
desktop({ "argv": ["set", "3/0/1/1", "中文也行"] })
desktop({ "argv": ["shot", "--json"] })
```

插件还会往系统提示词里注入一小段用法（约 5 行），告诉模型「先树后坐标」。想关掉：改 `cordis.patch.yml` 里 `promptSection: false`。

### 5.2 不装插件：让 agent 用 shell 调

§3.2 的安装脚本已经把准则写进 `~/.dsh/AGENTS.md`，agent 看到后会用 `dctl` 命令——效果一样，只是没有结构化工具入口（不会出现在工具列表里）。

### 5.3 验证 agent 真的会了

在 DSH 里说：**「用 desktop 工具打开计算器，7+8，把结果截图给我」**。

期望：agent 调 `launch calc` → `find 7 --app 计算器` → `act` → `shot`，最后给你一张显示 15 的截图。

## 6. 日常配方

### 6.1 填一个对话框（最常见的活）

```powershell
dctl wait --app 记事本 --timeout 10            # 等窗口出现
dctl find "" --app 记事本 --role Edit --limit 1  # 找输入区 → ref
dctl set <ref> "沈叙 via dctl 中文 OK"          # 直接写值，不用输入法
dctl read <ref>                                # 回读核对
```

### 6.2 点按钮（不用坐标）

```powershell
dctl find "确定" --app 记事本            # → 3/0/2/1  确定  Button
dctl act 3/0/2/1                        # 执行默认动作（Invoke/Toggle/Select）
```

按钮文字常带快捷键后缀（`确定(O)`）。`find` 做的是子串匹配，写 `确定` 命中；写全也行。

### 6.3 快捷键与打字

```powershell
dctl key ctrl+s        # 保存
dctl key alt+f4        # 关窗
dctl key win           # 开始菜单
dctl key ctrl+shift+esc
dctl type "纯 ASCII 才用 type"
```

中文、emoji 请用 `set`（Windows 的 `type` 也支持 Unicode，但长文本用 `set` 更稳）。

### 6.4 截图：给人看 / 给模型看

```powershell
dctl shot --json                          # 全屏，返回 path/width/height
dctl shot --monitor 2 --json              # 第二块屏
dctl shot C:\temp\a.png                   # 指定输出路径
```

人手截全屏用系统自带的 **Win+PrtSc**（存 `图片\屏幕截图`），不用额外绑定；agent 用 `dctl shot`。

### 6.5 批量点击列表项

```powershell
dctl find "第" --app 某某 --role ListItem --limit 20   # 一次拿多个 ref
dctl act 3/0/1/0/5                                     # 逐个点
```

### 6.6 界面没有无障碍树时（兜底）

```powershell
dctl move 800 600        # 移鼠标
dctl click 800 600       # 左键；--right 右键、--double 双击
dctl geom                # 看截图与实际像素比例（多显示器/缩放时必看）
```

坐标法要写死数字，换分辨率就废，所以只在画布/游戏/远程桌面里用。

## 7. 坐标与截图：三个坑

1. **DPI 缩放**：进程默认不感知 DPI，`dctl` 启动时就调 `SetProcessDPIAware`，报的坐标是物理像素。截图也是物理像素，两者一致——但**人眼在 150% 缩放下看到的「100 像素」不等于 100**。手动校准用 `dctl geom`。
2. **多显示器**：坐标可以是负的（主屏左边的副屏）。`dctl shot` 默认主屏，`--monitor N` 切屏；`apps` 会打印每个窗口的 x/y/w/h 便于判断在哪个屏。
3. **截图像素 ≠ 点击坐标**：截图是「读」，点击是「写」，两者混用是自动化最常见的 bug。能用 `act` 就别用 `click`。

## 8. 排错表

| 现象 | 原因 | 处理 |
|---|---|---|
| `dctl : 无法将…识别为 cmdlet` | PATH 没生效 | 新开终端；或 `& "$env:LOCALAPPDATA\dctl\dctl.cmd" apps` |
| 中文显示成乱码 | 文件被当 GBK 解析 / 控制台代码页 | 确认 `dctl.ps1` 带 UTF-8 BOM（本仓库自带）；`chcp 65001` 后再跑 |
| `apps` 里窗口名空白 | 该窗口还没建好 UIA 树 / 是提升权限进程 | 稍等重试；或以相同权限运行；或换 `dctl windows` 看 ref |
| `find` 找不到明显的按钮 | 深度不够 / 名字不同 / 自绘控件 | `dctl tree 记事本 --depth 24` 看真实结构；自绘的只能坐标点 |
| `set` 报错或无效 | 控件只读或没有 ValuePattern | 会自动回退「聚焦+剪贴板+Ctrl+V」；仍失败就 `focus` 后 `key ctrl+a`、`type` |
| `selftest` 卡住 | 已经开着一个同名记事本 / 弹出保存确认 | 关掉残留记事本再跑；`-SkipTest` 可跳过 |
| 点到了错误的窗口 | `--app` 命中了同名的旧窗口 | 用 `--title` 再筛一层，或先关旧窗口 |
| 提权窗口看不到 | UAC 隔离，普通权限进程碰不到 | 用管理员权限起 dctl；或人工完成那一步 |
| 脚本报「无法加载文件，未数字签名」 | 执行策略 | 用 `-ExecutionPolicy Bypass`（安装脚本已带） |

自检三连（贴给 agent 或自己排）：`dctl doctor` → `dctl geom` → `dctl selftest`。

## 9. 升级 / 卸载 / 迁移

```powershell
# 升级：拉新代码再跑一次安装脚本（幂等，AGENTS 不会重复写）
git pull && powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1

# 卸载
dsh plugin --profile desktop remove dsh-desktop-ctl   # 装过插件才需要
Remove-Item -Recurse "$env:LOCALAPPDATA\dctl"
# PATH 里那条可以留着，删完只是失效，不报错；要干净就从「环境变量」里删掉

# 迁移到另一台机器
# 整套东西就是 3 个文件（dctl.ps1 / dctl.cmd / 可选插件目录），拷过去跑安装脚本即可
```

## 10. ref 语法（看这篇就够）

- Windows 的 ref 是**从桌面根算起的绝对路径**：第一段是顶层窗口，之后每段是子节点序号，如 `3/0/1/2`。
- 它**不是**稳定 id：界面一变（换了控件、开了新窗口）就失效。**每次重新 `find`**，不要缓存。
- `find` 的输出第一列就是 ref，直接喂给 `act`、`set`、`read`、`info`。
- 加 `--json` 拿结构化结果（Windows 后端所有动词都支持）：

```json
dctl find "确定" --app 记事本 --json
{"ok":true,"count":1,"items":[{"ref":"3/0/2/1","role":"Button","name":"确定","id":"","x":812,"y":604,"w":88,"h":32}]}
```

## 附：Windows ↔ Linux 差异速查

| | Windows | Linux（GNOME Wayland 实测） |
|---|---|---|
| 树 | UI Automation | AT-SPI（要先 `toolkit-accessibility=true`） |
| ref | `3/0/1` | `11/0/0/.../3`（更长） |
| 输入 | SendInput，任意 Unicode | ydotool，中文只能靠 `set` |
| 截图 | 原生分辨率 | 640×360（被缩放），比例用 `geom` |
| 人手截屏 | Win+PrtSc | Ctrl+PrintScreen |
| 权限 | 普通用户 | 需 ydotoold 常驻 |

更多 Linux 细节与坑：[`TUTORIAL-linux.md`](`TUTORIAL-linux.md`)。
