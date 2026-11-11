<!-- desktop-ctl:begin -->
## 桌面操控：用 dctl，别从零试错

这台机器装了 `dctl`（无障碍树 + 键鼠注入 + 截图；Windows 走 UI Automation，Linux 走 AT-SPI）。要操作图形界面，按这个顺序：

1. **看结构**：`dctl apps` → `dctl windows` → `dctl tree <应用名> --depth 20` → `dctl find <文字> --app <应用名>`
2. **做动作**：`dctl act <ref>`（点按钮）、`dctl set <ref> "文本"`（写输入框）、`dctl read <ref>`（读文本）
3. **启动与等待**：`dctl launch notepad --wait 10`、`dctl wait --app 记事本 --timeout 10`、`dctl wait --text "保存成功"`
4. **快捷键**：`dctl key ctrl+s`、`dctl key alt+f4`、`dctl key win`（键码已内置）
5. **截图**：`dctl shot --json` → 返回路径与尺寸，再用 read_image 看。人手截全屏：Windows 按 `Win+PrtSc`（存 图片\屏幕截图），Linux 按 `Ctrl+PrintScreen`（存 ~/图片/截图）。
6. **自检**：`dctl doctor`（环境）、`dctl selftest`（全链路，会自己弹窗自己关掉）

硬规则：

- **元素级操作优先**（act/set/read）。零坐标、不抢焦点，是唯一稳的路径。
- **ref 不要缓存**：每次重新 `find` 拿新的。Windows 形如 `3/0/1`，Linux 是一条更长的索引链。
- **中文/emoji**：Windows 的 `type`/`set` 都可靠；Linux 上只用 `set`，`type`/`paste` 只对 ASCII 可靠。
- **截图只用来「看」**，别把截图像素当点击坐标：截图可能被缩小，比例用 `dctl geom` 现算。
- **网页任务走 browser_***（Chrome 桥），不要用坐标点网页。
- **找不到元素**先 `dctl tree <应用> --depth 24` 看真实结构：按钮文字常带快捷键，例如「确定(O)」。
- **别用的路线**：Windows 上别用 pyautogui/图像匹配猜坐标；Linux 上别用 `xdotool`、`gnome-screenshot`、portal Screenshot。
<!-- desktop-ctl:end -->
