#requires -Version 5.1
<#
  dctl.ps1 — Windows 桌面操控 CLI（dsh-desktop-ctl）
  与 Linux 版 dctl 同一套动词：apps/windows/tree/find/info/read/act/set/focus/
  wait/key/type/paste/clip/click/move/launch/shot/geom/doctor/selftest
  实现：UI Automation（无障碍树，元素级动作）+ SendInput（键鼠）+ GDI 截图
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# 输出编码：被其他进程（node 插件 / 管道）捕获时按 UTF-8 走。
# PS 5.1 默认按控制台代码页输出，中文会变成乱码 —— 这一行是跨进程读回的关键。
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
try { $OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

# ── 参数解析 ───────────────────────────────────────────────────────────────
$script:Argv = @($args)
$script:Opts = @{}
$script:Pos = @()

# --app 记事本 这种写法：选项值取紧随其后的位置参数
$script:Pos = @()
$i = 0
while ($i -lt $script:Argv.Count) {
  $a = $script:Argv[$i]
  if ($a -is [string] -and $a.StartsWith('--')) {
    $k = $a.Substring(2)
    if ($k.Contains('=')) {
      $j = $k.IndexOf('=')
      $script:Opts[$k.Substring(0, $j)] = $k.Substring($j + 1)
      $i++
      continue
    }
    if ($i + 1 -lt $script:Argv.Count -and -not ("$($script:Argv[$i + 1])".StartsWith('--'))) {
      $script:Opts[$k] = "$($script:Argv[$i + 1])"
      $i += 2
      continue
    }
    $script:Opts[$k] = $true
    $i++
    continue
  }
  $script:Pos += , "$a"
  $i++
}

function Opt([string]$name, $default = $null) {
  if ($script:Opts.ContainsKey($name)) { return $script:Opts[$name] }
  return $default
}
function Has([string]$name) { return $script:Opts.ContainsKey($name) -and $script:Opts[$name] -ne $false }
function Pos([int]$i, $default = $null) {
  if ($script:Pos.Count -gt $i) { return $script:Pos[$i] }
  return $default
}

$script:AsJson = (Has 'json')
$script:Walker = $null

# ── 输出 ──────────────────────────────────────────────────────────────────
function Write-Json([object]$obj) {
  $obj | ConvertTo-Json -Depth 8 -Compress
}
function Ok([string]$msg) {
  if (-not $script:AsJson) { Write-Output $msg }
}
function Fail([string]$msg, [int]$code = 1) {
  if ($script:AsJson) {
    Write-Output (Write-Json ([ordered]@{ ok = $false; error = $msg }))
  } else {
    [Console]::Error.WriteLine("dctl: $msg")
  }
  exit $code
}

# ── 原生调用 ───────────────────────────────────────────────────────────────
$script:NativeLoaded = $false
function Load-Native {
  if ($script:NativeLoaded) { return }
  Assert-Windows
  Add-Type -Namespace DctlNative -Name Win -UsingNamespace System.Runtime.InteropServices -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
[StructLayout(LayoutKind.Explicit)] public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
[StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public INPUTUNION u; }
[StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
[DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
[DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, int dx, int dy, uint dwData, IntPtr dwExtraInfo);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);
[DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

public static void Mouse(int x, int y, uint down, uint up, int times) {
  SetCursorPos(x, y);
  for (int i = 0; i < times; i++) {
    mouse_event(down, 0, 0, 0, IntPtr.Zero);
    mouse_event(up, 0, 0, 0, IntPtr.Zero);
  }
}
public static void Key(ushort vk, bool up) {
  INPUT[] a = new INPUT[1];
  a[0].type = 1;
  a[0].u.ki.wVk = vk;
  a[0].u.ki.wScan = (ushort)MapVirtualKey(vk, 0);
  a[0].u.ki.dwFlags = up ? 2u : 0u;
  SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
}
public static void UnicodeText(string s) {
  foreach (char c in s) {
    INPUT[] a = new INPUT[2];
    a[0].type = 1; a[0].u.ki.wVk = 0; a[0].u.ki.wScan = (ushort)c; a[0].u.ki.dwFlags = 4u;
    a[1].type = 1; a[1].u.ki.wVk = 0; a[1].u.ki.wScan = (ushort)c; a[1].u.ki.dwFlags = 6u;
    SendInput(2, a, Marshal.SizeOf(typeof(INPUT)));
  }
}
'@
  $script:NativeLoaded = $true
}

function Assert-Windows {
  if ($env:OS -ne 'Windows_NT') {
    Fail "dctl.ps1 是 Windows 后端，当前系统是 $([System.Environment]::OSVersion.VersionString)。Linux 请用同目录的 cli/linux/dctl"
  }
}

function Load-Uia {
  Assert-Windows
  if (-not ('System.Windows.Automation.AutomationElement' -as [type])) {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
  }
  if (-not $script:Walker) {
    $script:Walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
  }
  try { Load-Native; [void][DctlNative.Win]::SetProcessDPIAware() } catch { }
}

function Load-Drawing {
  Assert-Windows
  if (-not ('System.Drawing.Bitmap' -as [type])) { Add-Type -AssemblyName System.Drawing }
  if (-not ('System.Windows.Forms.Screen' -as [type])) { Add-Type -AssemblyName System.Windows.Forms }
}

# ── UIA 基础 ───────────────────────────────────────────────────────────────
function Get-Root { return [System.Windows.Automation.AutomationElement]::RootElement }

function Get-Kids($el) {
  $list = New-Object System.Collections.ArrayList
  try {
    $c = $script:Walker.GetFirstChild($el)
    while ($null -ne $c) {
      [void]$list.Add($c)
      $c = $script:Walker.GetNextSibling($c)
    }
  } catch { }
  return , $list.ToArray()
}

function Get-Safe($sb, $default = '') {
  try { return (& $sb) } catch { return $default }
}

function New-Desc($el, [string]$ref) {
  $n = Get-Safe { $el.Current.Name } ''
  $role = Get-Safe { ($el.Current.ControlType.ProgrammaticName -replace '^ControlType\.', '') } '?'
  $r = Get-Safe { $el.Current.BoundingRectangle } $null
  return [pscustomobject]([ordered]@{
      ref       = $ref
      role      = $role
      name      = $n
      id        = Get-Safe { $el.Current.AutomationId } ''
      cls       = Get-Safe { $el.Current.ClassName } ''
      pid       = Get-Safe { $el.Current.ProcessId } 0
      x         = if ($null -ne $r) { [int]$r.X } else { 0 }
      y         = if ($null -ne $r) { [int]$r.Y } else { 0 }
      w         = if ($null -ne $r) { [int]$r.Width } else { 0 }
      h         = if ($null -ne $r) { [int]$r.Height } else { 0 }
      enabled   = Get-Safe { $el.Current.IsEnabled } $false
      offscreen = Get-Safe { $el.Current.IsOffscreen } $true
    })
}

function Format-Desc($d) {
  $nm = if ($d.name) { $d.name } else { '(无名)' }
  $off = if ($d.offscreen) { '  离屏' } else { '' }
  return ("{0}  [{1}] {2}  ({3},{4} {5}x{6}){7}" -f $d.ref, $d.role, $nm, $d.x, $d.y, $d.w, $d.h, $off)
}

function Resolve-Ref([string]$ref) {
  Load-Uia
  $cur = Get-Root
  foreach ($part in $ref.Split('/')) {
    if ([string]::IsNullOrWhiteSpace($part)) { continue }
    $idx = 0
    if (-not [int]::TryParse($part, [ref]$idx)) { Fail "ref 不合法：$ref" }
    $kids = Get-Kids $cur
    if ($idx -lt 0 -or $idx -ge $kids.Count) { Fail "ref $ref 越界（第 $part 段只有 $($kids.Count) 个子元素）" }
    $cur = $kids[$idx]
  }
  return $cur
}

# ── 应用 / 窗口 ─────────────────────────────────────────────────────────────
function Get-TopWindows {
  Load-Uia
  $list = New-Object System.Collections.ArrayList
  $kids = Get-Kids (Get-Root)
  for ($i = 0; $i -lt $kids.Count; $i++) {
    $w = $kids[$i]
    $name = Get-Safe { $w.Current.Name } ''
    $pid = Get-Safe { $w.Current.ProcessId } 0
    $proc = ''
    if ($pid -gt 0) { $proc = Get-Safe { (Get-Process -Id $pid -ErrorAction Stop).ProcessName } '' }
    $r = Get-Safe { $w.Current.BoundingRectangle } $null
    [void]$list.Add([pscustomobject]@{
        index = $i
        ref   = "$i"
        name  = $name
        proc  = $proc
        pid   = $pid
        x     = if ($null -ne $r) { [int]$r.X } else { 0 }
        y     = if ($null -ne $r) { [int]$r.Y } else { 0 }
        w     = if ($null -ne $r) { [int]$r.Width } else { 0 }
        h     = if ($null -ne $r) { [int]$r.Height } else { 0 }
        el    = $w
      })
  }
  return , $list.ToArray()
}

function Select-Windows([string]$app, [string]$title) {
  $all = Get-TopWindows
  if (-not $app -and -not $title) { return , $all }
  $hits = @()
  foreach ($w in $all) {
    $okTitle = $true
    if ($title) { $okTitle = $w.name.ToLower().Contains($title.ToLower()) }
    $okApp = $true
    if ($app) {
      $okApp = ($w.proc.ToLower().Contains($app.ToLower())) -or ($w.name.ToLower().Contains($app.ToLower()))
    }
    if ($okTitle -and $okApp) { $hits += , $w }
  }
  if ($hits.Count -eq 0) {
    $seen = ($all | ForEach-Object { "$($_.proc)：$($_.name)" } | Select-Object -First 12) -join ' / '
    Fail "没有匹配的窗口（--app '$app' --title '$title'）。当前：$seen"
  }
  return , $hits
}

function Get-TargetWindow([string]$app, [string]$title) {
  $wins = Select-Windows $app $title
  return $wins[0]
}

# ── 元素匹配 / 搜索 ────────────────────────────────────────────────────────
function Test-Match($el, [string]$text, [string]$role) {
  if ($role) {
    $r = Get-Safe { ($el.Current.ControlType.ProgrammaticName -replace '^ControlType\.', '') } ''
    if (-not $r.ToLower().Contains($role.ToLower())) { return $false }
  }
  if ([string]::IsNullOrEmpty($text)) { return $true }
  $n = Get-Safe { $el.Current.Name } ''
  $aid = Get-Safe { $el.Current.AutomationId } ''
  return ($n.ToLower().Contains($text.ToLower())) -or ($aid.ToLower().Contains($text.ToLower()))
}

function Search-Tree([string]$app, [string]$title, [string]$text, [string]$role, [int]$maxDepth, [int]$limit) {
  Load-Uia
  $results = New-Object System.Collections.ArrayList
  $roots = @()
  if ($app -or $title) { $roots = Select-Windows $app $title } else { $roots = Get-TopWindows }
  foreach ($w in $roots) {
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($w.el, $w.ref, 0))
    while ($stack.Count -gt 0) {
      if ($results.Count -ge $limit) { break }
      $item = $stack.Pop()
      $el = $item[0]; $path = $item[1]; $d = $item[2]
      if ($d -gt 0 -and (Test-Match $el $text $role)) {
        [void]$results.Add([pscustomobject]@{ el = $el; desc = (New-Desc $el $path); win = $w.name })
      }
      if ($d -ge $maxDepth) { continue }
      $kids = Get-Kids $el
      for ($k = $kids.Count - 1; $k -ge 0; $k--) {
        $stack.Push(@($kids[$k], "$path/$k", ($d + 1)))
      }
    }
  }
  return , $results.ToArray()
}

# ── 文本读写 ───────────────────────────────────────────────────────────────
function Get-ElementText($el) {
  try {
    $p = $el.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    if ($p) { return [string]$p.Current.Value }
  } catch { }
  try {
    $p = $el.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    if ($p) { return ([string]$p.DocumentRange.GetText(-1)).Trim() }
  } catch { }
  return (Get-Safe { $el.Current.Name } '')
}

function Get-Pattern($el, $patternType) {
  try { return $el.GetCurrentPattern($patternType) } catch { return $null }
}

function Focus-Element($el) {
  Load-Native
  try { $el.SetFocus() } catch { }
  $h = Get-Safe { $el.Current.NativeWindowHandle } 0
  if (-not $h -or $h -eq 0) {
    $procid = Get-Safe { $el.Current.ProcessId } 0
    if ($procid -gt 0) { $h = Get-Safe { (Get-Process -Id $procid).MainWindowHandle } 0 }
  }
  if ($h -and $h -ne 0) {
    try { [void][DctlNative.Win]::ShowWindow([IntPtr]([int64]$h), 9) } catch { }
    try { [void][DctlNative.Win]::SetForegroundWindow([IntPtr]([int64]$h)) } catch { }
  }
}

function Set-ElementText($el, [string]$text) {
  $vp = Get-Pattern $el ([System.Windows.Automation.ValuePattern]::Pattern)
  if ($vp) {
    $ro = $false
    try { $ro = $vp.Current.IsReadOnly } catch { }
    if (-not $ro) {
      $vp.SetValue($text)
      return 'value'
    }
  }
  Focus-Element $el
  Start-Sleep -Milliseconds 150
  Set-Clipboard -Value $text
  Start-Sleep -Milliseconds 150
  Send-Combo 'ctrl+a'
  Start-Sleep -Milliseconds 80
  Send-Combo 'ctrl+v'
  return 'paste'
}

# ── 键盘 ──────────────────────────────────────────────────────────────────
$script:Vk = @{
  'ctrl' = 0x11; 'control' = 0x11; 'alt' = 0x12; 'shift' = 0x10; 'win' = 0x5B; 'super' = 0x5B; 'meta' = 0x5B
  'enter' = 0x0D; 'return' = 0x0D; 'tab' = 0x09; 'esc' = 0x1B; 'escape' = 0x1B; 'space' = 0x20
  'backspace' = 0x08; 'delete' = 0x2E; 'del' = 0x2E; 'insert' = 0x2D
  'home' = 0x24; 'end' = 0x23; 'pageup' = 0x21; 'pagedown' = 0x22
  'up' = 0x26; 'down' = 0x28; 'left' = 0x25; 'right' = 0x27
  'print' = 0x2C; 'printscreen' = 0x2C; 'capslock' = 0x14; 'apps' = 0x5D
}
function Resolve-Key([string]$name) {
  $k = $name.ToLower()
  if ($script:Vk.ContainsKey($k)) { return [int]$script:Vk[$k] }
  if ($k -match '^f([1-9]|1[0-9]|2[0-4])$') { return (0x70 + [int]$Matches[1] - 1) }
  if ($k.Length -eq 1) {
    $c = $k.ToUpper()[0]
    if ([char]::IsLetterOrDigit($c)) { return [int][char]$c }
  }
  Fail "不认识的按键：$name"
}

function Send-Combo([string]$combo) {
  Load-Native
  $parts = @($combo.Split('+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if ($parts.Count -eq 0) { Fail '按键组合为空' }
  $vks = @($parts | ForEach-Object { Resolve-Key $_ })
  for ($k = 0; $k -lt $vks.Count - 1; $k++) { [DctlNative.Win]::Key([uint16]$vks[$k], $false) }
  [DctlNative.Win]::Key([uint16]$vks[$vks.Count - 1], $false)
  Start-Sleep -Milliseconds 30
  [DctlNative.Win]::Key([uint16]$vks[$vks.Count - 1], $true)
  for ($k = $vks.Count - 2; $k -ge 0; $k--) { [DctlNative.Win]::Key([uint16]$vks[$k], $true) }
}

function Send-Text([string]$text) {
  Load-Native
  $nonBmp = $false
  foreach ($ch in $text.ToCharArray()) { if ([int]$ch -ge 0xD800 -and [int]$ch -le 0xDFFF) { $nonBmp = $true } }
  if (-not $nonBmp) {
    [DctlNative.Win]::UnicodeText($text)
    return
  }
  Set-Clipboard -Value $text
  Start-Sleep -Milliseconds 150
  Send-Combo 'ctrl+v'
}

# ── 截图 ──────────────────────────────────────────────────────────────────
function Get-ShotDir {
  $pics = [Environment]::GetFolderPath('MyPictures')
  if (-not $pics) { $pics = Join-Path $env:USERPROFILE 'Pictures' }
  $dir = Join-Path $pics '截图'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  return $dir
}

function Take-Shot([string]$outPath, [int]$monitor = 0) {
  Load-Drawing
  if (-not $outPath) {
    $outPath = Join-Path (Get-ShotDir) ("dctl {0}.png" -f (Get-Date -Format 'yyyy-MM-dd HH-mm-ss'))
  }
  $bounds = $null
  if ($monitor -gt 0) {
    $screens = [System.Windows.Forms.Screen]::AllScreens
    if ($monitor -gt $screens.Count) { Fail "没有第 $monitor 块显示器（共 $($screens.Count) 块）" }
    $bounds = $screens[$monitor - 1].Bounds
  } else {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
  }
  $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bmp.Size)
  $dir = Split-Path -Parent $outPath
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
  return [pscustomobject]@{ path = $outPath; width = $bounds.Width; height = $bounds.Height; bytes = (Get-Item $outPath).Length }
}

# ── 子命令 ─────────────────────────────────────────────────────────────────
function Cmd-Help {
  @'
dctl — 桌面操控（Windows）

看结构
  dctl apps                                顶层窗口
  dctl tree <app> [--title T] [--depth N]  打印无障碍树
  dctl find <文字> [--app A] [--title T] [--role R] [--depth N] [--limit N]
  dctl info <ref>

做动作
  dctl read <ref>
  dctl act <ref> [--action NAME]           默认第一个可用动作（Invoke/Toggle/Select/Expand）
  dctl set <ref> <文本>                     中文/emoji 均可；只读控件回退为粘贴
  dctl focus <ref>
  dctl click <x> <y> [--ref R] [--right] [--double]
  dctl move <x> <y>

键盘 / 剪贴板
  dctl key ctrl+s
  dctl type <文本>                          任意 Unicode（emoji 自动走剪贴板）
  dctl paste [文本]
  dctl clip [文本]

进程 / 等待 / 采集
  dctl launch notepad [--wait N]
  dctl wait --app A / --title T / --text S [--timeout N]
  dctl shot [--out P] [--monitor N] [--json]
  dctl geom [--json]
  dctl doctor [--json]
  dctl selftest

全局：--json 输出结构化结果。ref 形如 3/0/1，从桌面根窗口算起，可直接喂给 act/set/read。
'@ | Write-Output
}

function Cmd-Apps([switch]$IncludeEmpty) {
  $wins = Get-TopWindows
  $items = @()
  foreach ($w in $wins) {
    if (-not $IncludeEmpty -and [string]::IsNullOrWhiteSpace($w.name)) { continue }
    $items += [pscustomobject]@{ ref = $w.ref; name = $w.name; proc = $w.proc; pid = $w.pid; x = $w.x; y = $w.y; w = $w.w; h = $w.h }
  }
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; os = 'windows'; count = $items.Count; items = $items }) | Write-Output; return }
  foreach ($it in $items) {
    $who = if ($it.proc) { $it.proc } else { "pid $($it.pid)" }
    $nm = if ($it.name) { $it.name } else { '(无名)' }
    Write-Output ("{0,-6} {1,-22} {2}" -f $it.ref, $who, $nm)
  }
  Write-Output "共 $($items.Count) 个顶层窗口"
}

function Cmd-Tree {
  $app = [string](Opt 'app' '')
  $title = [string](Opt 'title' '')
  if (-not $app -and -not $title -and $script:Pos.Count -gt 1) { $app = [string](Pos 1) }
  $depth = 10
  if (Opt 'depth') { $depth = [int](Opt 'depth') }
  $w = Get-TargetWindow $app $title
  $lines = New-Object System.Collections.ArrayList
  $stack = New-Object System.Collections.Stack
  $stack.Push(@($w.el, $w.ref, 0))
  while ($stack.Count -gt 0) {
    $item = $stack.Pop()
    $el = $item[0]; $path = $item[1]; $d = $item[2]
    [void]$lines.Add((('  ' * $d) + (Format-Desc (New-Desc $el $path))))
    if ($d -ge $depth) { continue }
    $kids = Get-Kids $el
    for ($k = $kids.Count - 1; $k -ge 0; $k--) {
      $stack.Push(@($kids[$k], "$path/$k", ($d + 1)))
    }
  }
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; window = $w.name; lines = $lines }) | Write-Output; return }
  $lines | Write-Output
}

function Cmd-Find {
  $text = [string](Pos 1 '')
  if (-not $text -and -not (Has 'role')) { Fail 'find 需要文字或 --role' }
  $depth = 12; if (Opt 'depth') { $depth = [int](Opt 'depth') }
  $limit = 40; if (Opt 'limit') { $limit = [int](Opt 'limit') }
  $hits = Search-Tree ([string](Opt 'app' '')) ([string](Opt 'title' '')) $text ([string](Opt 'role' '')) $depth $limit
  $items = @()
  foreach ($h in $hits) {
    $items += [pscustomobject]@{ ref = $h.desc.ref; role = $h.desc.role; name = $h.desc.name; id = $h.desc.id; x = $h.desc.x; y = $h.desc.y; w = $h.desc.w; h = $h.desc.h; window = $h.win }
  }
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; count = $items.Count; items = $items }) | Write-Output; return }
  foreach ($it in $items) {
    $nm = if ($it.name) { $it.name } else { '(无名)' }
    Write-Output ("{0}  [{1}] {2}  ({3},{4} {5}x{6})  ← {7}" -f $it.ref, $it.role, $nm, $it.x, $it.y, $it.w, $it.h, $it.window)
  }
  if ($items.Count -eq 0) { Write-Output "没找到（深度 $depth）" }
}

function Cmd-Info {
  $ref = [string](Pos 1 ''); if (-not $ref) { Fail 'info 需要 ref' }
  $el = Resolve-Ref $ref
  $d = New-Desc $el $ref
  $patterns = @()
  foreach ($p in @('InvokePattern', 'ValuePattern', 'TextPattern', 'TogglePattern', 'SelectionItemPattern', 'ExpandCollapsePattern', 'RangeValuePattern', 'ScrollPattern', 'GridPattern', 'WindowPattern', 'SelectionPattern', 'LegacyIAccessiblePattern')) {
    $t = [System.Windows.Automation.AutomationPattern]::$p
    if ($t -and (Get-Pattern $el $t)) { $patterns += $p }
  }
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; element = $d; patterns = $patterns }) | Write-Output; return }
  Format-Desc $d | Write-Output
  Write-Output "  automationId: $($d.id)"
  Write-Output "  class: $($d.cls)  pid: $($d.pid)  enabled: $($d.enabled)"
  Write-Output "  模式: $($patterns -join ', ')"
  $txt = Get-ElementText $el
  if ($txt) { Write-Output "  文本: $txt" }
}

function Cmd-Read {
  $ref = [string](Pos 1 ''); if (-not $ref) { Fail 'read 需要 ref' }
  $el = Resolve-Ref $ref
  $txt = Get-ElementText $el
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; ref = $ref; text = $txt }) | Write-Output; return }
  Write-Output $txt
}

function Cmd-Act {
  $ref = [string](Pos 1 ''); if (-not $ref) { Fail 'act 需要 ref' }
  $want = [string](Opt 'action' '')
  $el = Resolve-Ref $ref
  $order = @(
    @{ name = 'Invoke'; type = [System.Windows.Automation.InvokePattern]::Pattern; run = { param($p) $p.Invoke() } },
    @{ name = 'Toggle'; type = [System.Windows.Automation.TogglePattern]::Pattern; run = { param($p) $p.Toggle() } },
    @{ name = 'Select'; type = [System.Windows.Automation.SelectionItemPattern]::Pattern; run = { param($p) $p.Select() } },
    @{ name = 'ExpandCollapse'; type = [System.Windows.Automation.ExpandCollapsePattern]::Pattern; run = { param($p) $p.Expand() } }
  )
  foreach ($p in $order) {
    if ($want -and ($p.name.ToLower() -ne $want.ToLower())) { continue }
    $pat = Get-Pattern $el $p.type
    if ($pat) {
      try {
        & $p.run $pat
        if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; ref = $ref; action = $p.name }) | Write-Output } else { Ok "已执行 $($p.name)（ref $ref）" }
        return
      } catch { }
    }
  }
  $d = New-Desc $el $ref
  if ($d.w -le 0 -or $d.h -le 0) { Fail "ref $ref 没有可用动作，也无法定位坐标" }
  $cx = $d.x + [int]($d.w / 2); $cy = $d.y + [int]($d.h / 2)
  Focus-Element $el
  [DctlNative.Win]::Mouse($cx, $cy, [uint32]0x0002, [uint32]0x0004, 1)
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; ref = $ref; action = 'click'; x = $cx; y = $cy }) | Write-Output } else { Ok "无标准动作，已点击中心 ($cx,$cy)" }
}

function Cmd-Set {
  $ref = [string](Pos 1 ''); if (-not $ref) { Fail 'set 需要 ref 和文本' }
  $text = [string](Pos 2 '')
  $el = Resolve-Ref $ref
  $how = Set-ElementText $el $text
  Start-Sleep -Milliseconds 150
  $back = Get-ElementText $el
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; ref = $ref; text = $text; readback = $back; method = $how }) | Write-Output; return }
  if ($back -eq $text) { Ok "已写入（$how），回读一致" } else { Ok "已写入（$how），回读：$back" }
}

function Cmd-Focus {
  $ref = [string](Pos 1 ''); if (-not $ref) { Fail 'focus 需要 ref' }
  Focus-Element (Resolve-Ref $ref)
  Ok "已聚焦 ref $ref"
}

function Cmd-Key {
  $combo = [string](Pos 1 ''); if (-not $combo) { Fail 'key 需要组合键，例如 ctrl+s' }
  Send-Combo $combo
  Ok "已发送 $combo"
}

function Cmd-Type {
  $text = [string](Pos 1 ''); if (-not $text) { Fail 'type 需要文本' }
  Send-Text $text
  Ok "已输入 $($text.Length) 个字符"
}

function Cmd-Paste {
  $text = [string](Pos 1 '')
  if ($text) { Set-Clipboard -Value $text; Start-Sleep -Milliseconds 120 }
  Send-Combo 'ctrl+v'
  Ok '已粘贴'
}

function Cmd-Clip {
  $text = [string](Pos 1 '')
  if ($text) { Set-Clipboard -Value $text; Ok "已写入剪贴板（$($text.Length) 字）"; return }
  $cur = Get-Clipboard -Raw
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; text = $cur }) | Write-Output; return }
  Write-Output $cur
}

function Cmd-Click {
  Load-Native
  $ref = [string](Opt 'ref' '')
  $x = 0; $y = 0
  if ($ref) {
    $d = New-Desc (Resolve-Ref $ref) $ref
    $x = $d.x + [int]($d.w / 2); $y = $d.y + [int]($d.h / 2)
  } else {
    $xs = [string](Pos 1 ''); $ys = [string](Pos 2 '')
    if (-not $xs -or -not $ys) { Fail 'click 需要 x y 或 --ref' }
    $x = [int]$xs; $y = [int]$ys
  }
  $down = 0x0002; $up = 0x0004
  if (Has 'right') { $down = 0x0008; $up = 0x0010 }
  $times = 1; if (Has 'double') { $times = 2 }
  [DctlNative.Win]::Mouse($x, $y, [uint32]$down, [uint32]$up, $times)
  Ok "已点击 ($x,$y)"
}

function Cmd-Move {
  Load-Native
  $x = [int](Pos 1 ''); $y = [int](Pos 2 '')
  [void][DctlNative.Win]::SetCursorPos($x, $y)
  Ok "指针 → ($x,$y)"
}

function Cmd-Launch {
  $cmd = [string](Pos 1 ''); if (-not $cmd) { Fail 'launch 需要命令或路径' }
  $p = Start-Process -FilePath $cmd -PassThru -ErrorAction Stop
  $waitN = 0; if (Opt 'wait') { $waitN = [int](Opt 'wait') }
  if ($waitN -gt 0) {
    $deadline = (Get-Date).AddSeconds($waitN)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 250
      try { $p.Refresh() } catch { }
      if ($p.HasExited) { break }
      $h = Get-Safe { $p.MainWindowHandle } 0
      if ($h -and $h -ne 0) { break }
    }
  }
  $h2 = Get-Safe { $p.MainWindowHandle } 0
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; pid = $p.Id; hwnd = [int64]$h2; name = (Get-Safe { $p.ProcessName } '') }) | Write-Output; return }
  Ok "已启动 $cmd（pid $($p.Id)）"
}

function Cmd-Wait {
  $timeout = 20; if (Opt 'timeout') { $timeout = [int](Opt 'timeout') }
  $app = [string](Opt 'app' ''); $title = [string](Opt 'title' ''); $text = [string](Opt 'text' '')
  if (-not $app -and -not $title -and -not $text) { Fail 'wait 需要 --app / --title / --text' }
  Load-Uia
  $deadline = (Get-Date).AddSeconds($timeout)
  while ((Get-Date) -lt $deadline) {
    try {
      if ($text) {
        $hits = Search-Tree $app $title $text '' 10 5
        if ($hits.Count -gt 0) {
          if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; matched = $hits[0].desc.ref; text = $text }) | Write-Output } else { Ok "等到文字：$text（ref $($hits[0].desc.ref)）" }
          return
        }
      } else {
        $wins = @()
        try { $wins = Select-Windows $app $title } catch { $wins = @() }
        if ($wins.Count -gt 0) {
          if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; window = $wins[0].name; ref = $wins[0].ref }) | Write-Output } else { Ok "等到窗口：$($wins[0].name)" }
          return
        }
      }
    } catch { }
    Start-Sleep -Milliseconds 400
  }
  Fail "等待超时（$timeout s）"
}

function Cmd-Shot {
  $out = [string](Opt 'out' '')
  $mon = 0; if (Opt 'monitor') { $mon = [int](Opt 'monitor') }
  $shot = Take-Shot $out $mon
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; path = $shot.path; width = $shot.width; height = $shot.height; bytes = $shot.bytes }) | Write-Output; return }
  Write-Output $shot.path
}

function Cmd-Geom {
  Load-Drawing
  $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
  $prim = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $dpi = 96.0
  try {
    $bmp = New-Object System.Drawing.Bitmap(1, 1)
    $dpi = $bmp.HorizontalResolution
    $bmp.Dispose()
  } catch { }
  $mons = @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object { [ordered]@{ name = $_.DeviceName; primary = $_.Primary; w = $_.Bounds.Width; h = $_.Bounds.Height } })
  if ($script:AsJson) {
    Write-Json ([ordered]@{
        ok = $true; os = 'windows'
        screen = [ordered]@{ x = $vs.Left; y = $vs.Top; w = $vs.Width; h = $vs.Height }
        primary = [ordered]@{ x = $prim.Left; y = $prim.Top; w = $prim.Width; h = $prim.Height }
        monitors = $mons
        dpi = [math]::Round($dpi, 0)
        scale = [math]::Round($dpi / 96.0, 2)
      }) | Write-Output
    return
  }
  Write-Output "虚拟桌面: $($vs.Width)x$($vs.Height) @ ($($vs.Left),$($vs.Top))"
  Write-Output "主屏:     $($prim.Width)x$($prim.Height)"
  Write-Output "DPI:      $([math]::Round($dpi,0))（缩放 $([math]::Round($dpi/96.0,2))x）"
  Write-Output "显示器:   $(($mons | ForEach-Object { "$($_.name) $($_.w)x$($_.h)" }) -join ' / ')"
  Write-Output "说明:     本进程已声明 DPI 感知，UIA 坐标 = 物理像素 = 鼠标坐标"
}

function Cmd-Doctor {
  $script:Checks = @()
  function Add-Check([string]$nm, [bool]$ok, [string]$detail) {
    $script:Checks += [pscustomobject]@{ name = $nm; ok = $ok; detail = $detail }
  }
  Add-Check 'powershell' $true "$($PSVersionTable.PSVersion) / $([System.Environment]::OSVersion.VersionString)"
  Add-Check 'user-interactive' ([System.Environment]::UserInteractive) $(if ([System.Environment]::UserInteractive) { '交互式会话' } else { '非交互会话（服务/SSH 无桌面），键鼠注入会失败' })
  $uia = $true; $uiaDetail = ''
  try { Load-Uia; $uiaDetail = "顶层窗口 $((Get-TopWindows).Count) 个" } catch { $uia = $false; $uiaDetail = "$($_.Exception.Message)" }
  Add-Check 'ui-automation' $uia $uiaDetail
  $draw = $true; $drawDetail = ''
  try { Load-Drawing; $drawDetail = "虚拟桌面 $([System.Windows.Forms.SystemInformation]::VirtualScreen.Width)x$([System.Windows.Forms.SystemInformation]::VirtualScreen.Height)" } catch { $draw = $false; $drawDetail = "$($_.Exception.Message)" }
  Add-Check 'screen-capture' $draw $drawDetail
  $clip = $true; $clipDetail = ''
  try { $c = Get-Clipboard -Raw; $clipDetail = "可读写（当前 $($c.Length) 字）" } catch { $clip = $false; $clipDetail = "$($_.Exception.Message)" }
  Add-Check 'clipboard' $clip $clipDetail
  $input = $true
  try { Load-Native; $pt = New-Object DctlNative.Win+POINT; [void][DctlNative.Win]::GetCursorPos([ref]$pt) } catch { $input = $false }
  Add-Check 'input-injection' $input 'SendInput 可用（键鼠注入）'
  Add-Check 'execution-policy' $true "$(Get-ExecutionPolicy)"
  $admin = $false
  try { $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
  Add-Check 'elevation' $true $(if ($admin) { '管理员' } else { '普通用户（操作管理员窗口会受限）' })
  if ($script:AsJson) { Write-Json ([ordered]@{ ok = $true; checks = $script:Checks }) | Write-Output; return }
  foreach ($c in $script:Checks) {
    $mark = if ($c.ok) { 'OK  ' } else { 'FAIL' }
    Write-Output ("{0} {1,-18} {2}" -f $mark, $c.name, $c.detail)
  }
  if (@($script:Checks | Where-Object { -not $_.ok }).Count -gt 0) { exit 1 }
}

function Cmd-Selftest {
  Write-Output '— dctl selftest（Windows）—'
  $p = $null; $fail = 0
  try {
    Load-Uia
    $wins = Get-TopWindows
    Write-Output "1) UIA 就绪，顶层窗口 $($wins.Count) 个"
  } catch {
    Write-Output "1) UIA 不可用：$($_.Exception.Message)"; exit 1
  }
  try {
    $p = Start-Process notepad.exe -PassThru
    Write-Output "2) 启动 notepad（pid $($p.Id)）"
  } catch {
    Write-Output "2) 无法启动 notepad：$($_.Exception.Message)"; exit 1
  }
  $win = $null
  $deadline = (Get-Date).AddSeconds(15)
  while ((Get-Date) -lt $deadline -and -not $win) {
    Start-Sleep -Milliseconds 400
    try { $win = Get-TargetWindow 'notepad' '' } catch { }
  }
  if (-not $win) { Write-Output '3) 15s 内没等到记事本窗口'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; exit 1 }
  Write-Output "3) 找到窗口：$($win.name)（ref $($win.ref)）"

  $edits = Search-Tree 'notepad' '' '' 'Edit' 12 5
  if ($edits.Count -eq 0) { $edits = Search-Tree 'notepad' '' '' 'Document' 12 5 }
  if ($edits.Count -eq 0) { Write-Output '4) 没找到文本控件（记事本控件类型可能不同）'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; exit 1 }
  Write-Output "4) 文本控件 ref $($edits[0].desc.ref) [$($edits[0].desc.role)] $($edits[0].desc.name)"
  $mark = '沈叙 selftest 中文 123'
  try {
    Focus-Element $edits[0].el
    Set-ElementText $edits[0].el $mark | Out-Null
    Start-Sleep -Milliseconds 400
    $back = Get-ElementText $edits[0].el
    if ($back -match 'selftest') { Write-Output "5) 写入并回读成功：$back" }
    else {
      Send-Text $mark
      Start-Sleep -Milliseconds 400
      $back2 = Get-ElementText $edits[0].el
      if ($back2 -match 'selftest') { Write-Output "5) 键盘注入成功：$back2" }
      else { Write-Output "5) 回读不符（读回：'$back2'）"; $fail = 1 }
    }
  } catch {
    Write-Output "5) 写入失败：$($_.Exception.Message)"; $fail = 1
  }
  try {
    $shot = Take-Shot '' 0
    Write-Output "6) 截图 $($shot.width)x$($shot.height) → $($shot.path)"
  } catch {
    Write-Output "6) 截图失败：$($_.Exception.Message)"; $fail = 1
  }
  Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  Write-Output '（已关闭记事本，不保存）'
  if ($fail -eq 0) { Write-Output '自检通过' } else { Write-Output '自检有失败项'; exit 1 }
}

# ── 分发 ──────────────────────────────────────────────────────────────────
$verb = [string](Pos 0 '')
switch ($verb) {
  'apps' { Cmd-Apps }
  'windows' { Cmd-Apps -IncludeEmpty }
  'tree' { Cmd-Tree }
  'find' { Cmd-Find }
  'info' { Cmd-Info }
  'read' { Cmd-Read }
  'act' { Cmd-Act }
  'set' { Cmd-Set }
  'focus' { Cmd-Focus }
  'key' { Cmd-Key }
  'type' { Cmd-Type }
  'paste' { Cmd-Paste }
  'clip' { Cmd-Clip }
  'click' { Cmd-Click }
  'move' { Cmd-Move }
  'launch' { Cmd-Launch }
  'wait' { Cmd-Wait }
  'shot' { Cmd-Shot }
  'geom' { Cmd-Geom }
  'doctor' { Cmd-Doctor }
  'selftest' { Cmd-Selftest }
  'version' { Write-Output 'dctl 2.0.0 (windows)' }
  '--version' { Write-Output 'dctl 2.0.0 (windows)' }
  '-v' { Write-Output 'dctl 2.0.0 (windows)' }
  'help' { Cmd-Help }
  '--help' { Cmd-Help }
  '-h' { Cmd-Help }
  '' { Cmd-Help }
  default { Fail "未知子命令：$verb（dctl help 看用法）" }
}
