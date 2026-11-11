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

# 02 — 记事本：启动 → 打字（中文）→ 回读 → 截图
# 关键点：写文字用 set 或 type，不要用 key 一个个拼。

Step "启动记事本并等窗口"
dctl launch notepad --wait 10
dctl wait --app notepad --timeout 10

Step "找编辑区"
$line = dctl find "" --app notepad --role Edit --limit 1 | Select-Object -First 1
Write-Host ("  " + $line)
$ref = ($line -split "\s+")[0]
if (-not $ref) { throw "没找到编辑区，用 dctl tree notepad --depth 12 看看结构" }

Step "写中文（不需要输入法、不抢焦点）"
$text = "沈叙 via dctl 中文 OK " + (Get-Date -Format "HH:mm:ss")
dctl set $ref $text

Step "回读校验"
$back = dctl read $ref
Write-Host ("  读回: " + $back)
if ($back -notmatch "dctl") { Write-Host "  读回内容和写入不一致，见 docs\TUTORIAL-windows.md 的排错" -ForegroundColor Yellow }

Step "截图留证"
dctl shot --json | ConvertFrom-Json | ForEach-Object { Write-Host ("  " + $_.path) }
