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

# 03 — 计算器：按 ref 点按钮（元素级，不用坐标）
# 按钮名就是界面上的字；"+" 这类符号直接用引号包起来。

Step "启动计算器"
dctl launch calc --wait 10
dctl wait --app 计算器 --timeout 10

function Press([string]$label) {
  $hit = dctl find $label --app 计算器 --role Button --limit 1 | Select-Object -First 1
  if (-not $hit) { throw ("找不到按钮: " + $label) }
  $r = ($hit -split "\s+")[0]
  Write-Host ("  按 " + $label + " → ref " + $r)
  dctl act $r
  Start-Sleep -Milliseconds 200
}

Press "7"
Press "加"
Press "8"
Press "等于"

Step "读结果：显示区通常在结果里，读不到就截图看"
$shown = dctl find "" --app 计算器 --role Text --limit 3
Write-Host ("  " + $shown)
dctl shot --json | ConvertFrom-Json | ForEach-Object { Write-Host ("  截图: " + $_.path) }
