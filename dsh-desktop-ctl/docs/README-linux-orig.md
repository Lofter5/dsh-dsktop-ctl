# desktop-ctl

在 Linux 桌面（GNOME/Wayland 优先，X11 亦可）上让 agent **完整操控电脑**的最小工具包。

核心思路一句话：**用无障碍树（AT-SPI）做元素级操作当主干，用 ydotool 补键鼠，用截图补「看结果」。**

```
dctl apps / windows / tree / find     看界面结构
dctl act / set / read / focus         点按钮、填表单、读文本（零坐标、不抢焦点）
dctl launch / wait                    启动应用、等界面出现
dctl key / type / paste / click       快捷键、打字、兜底坐标点击
dctl shot                             截图（GNOME：PrintScreen + Space；同一动作也绑在 Ctrl+PrintScreen）
dctl doctor / selftest / geom         自检、坐标系体检
```

## 30 秒开始

```bash
sudo ./install.sh --system     # 系统依赖 + ydotoold 服务（一次）
./install.sh --keybinding --agents   # 装 dctl、开无障碍、绑 Ctrl+PrintScreen、写 AGENTS
dctl selftest                  # 全链路验证：写中文 → 点确定 → 截图
```

## 典型用法

```bash
dctl launch gnome-calculator                      # 打开计算器
dctl find "7" --app 计算器 --role button           # 找到按钮 → ref
dctl act 3/0/0/0/12/0/0/0/0/0/0/0/0/0/1/0          # 点它
dctl shot --json                                  # 看结果
```

完整说明见 **[TUTORIAL.md](TUTORIAL.md)**；给 agent 的行为准则见 **[AGENTS-desktop-ctl.md](AGENTS-desktop-ctl.md)**。

## 目录

| 文件 | 作用 |
|---|---|
| `dctl` | 单文件 CLI（Python3 + gi，无第三方依赖） |
| `install.sh` | 安装（用户级 / `--system` 系统级） |
| `TUTORIAL.md` | 教程：原理、安装、配方、排错 |
| `AGENTS-desktop-ctl.md` | 粘进 `~/.dsh/AGENTS.md`，让 DSH 知道该用 dctl |
| `skill/desktop-control.md` | 记忆页版本（`~/.memory/skills/`） |
| `examples/` | 可直接跑的小例子 |
