# 公共小工具：找到 dctl。装了就优先用 PATH 里的，否则用仓库里的脚本。
$script:Dctl = $null
$c = Get-Command dctl.cmd -ErrorAction SilentlyContinue
if ($c) { $script:Dctl = $c.Source }
if (-not $script:Dctl) {
  $p = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'cli\windows\dctl.ps1'
  if (Test-Path $p) { $script:Dctl = $p } else { throw "找不到 dctl：先跑 install.ps1，或把本脚本放在仓库的 examples\windows\ 下" }
}
function dctl { & $script:Dctl @args }
function Step([string]$m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }

# 01 — 最基本的三步：看窗口、看结构、截图
# 在 Windows PowerShell 里跑：  powershell -NoProfile -ExecutionPolicy Bypass -File 01-basic.ps1

Step "环境自检"
dctl doctor

Step "顶层窗口"
dctl apps

Step "截图（拿路径后可以用看图工具或 DSH 的 read_image 打开）"
$shot = dctl shot --json | ConvertFrom-Json
Write-Host ("  截图: " + $shot.path + "  " + $shot.width + "x" + $shot.height)

Step "整个桌面的无障碍树前 2 层（UI Automation 从桌面根算起）"
dctl tree --depth 2
