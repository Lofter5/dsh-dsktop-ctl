#Requires -Version 5.1
<#
  install.ps1 — dsh-desktop-ctl 的 Windows 安装脚本

  做四件事（都不需要管理员权限）：
    1) 把 dctl.ps1 / dctl.cmd 复制到 %LOCALAPPDATA%\dctl（可用 -Dest 改）
    2) 把那个目录加进当前用户的 PATH
    3) 把操控准则追加到 %USERPROFILE%\.dsh\AGENTS.md（DSH 每次会话都会读）
    4) 把技能页复制到 %USERPROFILE%\.memory\skills\desktop-control.md
  最后跑 doctor + selftest 验证。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Dest D:\tools\dctl -NoPath
    powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -Plugin
#>
param(
  [string]$Dest = (Join-Path $env:LOCALAPPDATA 'dctl'),
  [switch]$NoPath,
  [switch]$SkipTest,
  [switch]$SkipAgents,
  [switch]$Plugin,
  [string]$Profile = 'desktop'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }

function Say([string]$m) { Write-Host ""; Write-Host "== $m" -ForegroundColor Cyan }
function Die([string]$m) { Write-Host "错误: $m" -ForegroundColor Red; exit 1 }

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($env:OS -ne 'Windows_NT') { Die "install.ps1 只用于 Windows。Linux 请用同目录的 install.sh" }

Say "检查来源文件"
$srcPs1 = Join-Path $Here 'cli\windows\dctl.ps1'
$srcCmd = Join-Path $Here 'cli\windows\dctl.cmd'
if (-not (Test-Path $srcPs1)) { Die "找不到 $srcPs1（请用完整仓库目录，别只拷安装脚本）" }
Write-Host "  dctl.ps1 : $srcPs1"
Write-Host "  dctl.cmd : $srcCmd"

Say "安装到 $Dest"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
Copy-Item -Force $srcPs1 (Join-Path $Dest 'dctl.ps1')
Copy-Item -Force $srcCmd (Join-Path $Dest 'dctl.cmd')
Write-Host "  已复制 dctl.ps1 / dctl.cmd"

$dctl = Join-Path $Dest 'dctl.ps1'
function Dctl { & $dctl @args }

Say "环境自检（doctor）"
try { Dctl doctor } catch { Write-Host "  doctor 失败: $($_.Exception.Message)" -ForegroundColor Yellow }

if (-not $NoPath) {
  Say "把 $Dest 加进用户 PATH"
  $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
  if (-not $cur) { $cur = '' }
  $parts = @($cur -split ';' | Where-Object { $_ -and $_.Trim() })
  if ($parts -contains $Dest) {
    Write-Host "  已在 PATH 里，跳过"
  } else {
    $new = (@($parts) + $Dest) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $new, 'User')
    Write-Host "  已写入用户 PATH（新开的终端才生效）"
  }
  $env:Path = $env:Path + ';' + $Dest
}

if (-not $SkipAgents) {
  Say "写入 DSH 的桌面操控准则"
  $agents = Join-Path $env:USERPROFILE '.dsh\AGENTS.md'
  $snip = Join-Path $Here 'AGENTS-desktop-ctl.md'
  if (-not (Test-Path $snip)) {
    Write-Host "  没有 AGENTS-desktop-ctl.md，跳过"
  } else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $agents) | Out-Null
    $has = (Test-Path $agents) -and (Select-String -Path $agents -Pattern 'desktop-ctl:begin' -Quiet)
    if ($has) {
      Write-Host "  已经写过（有 desktop-ctl:begin 标记），跳过"
    } else {
      $body = (Get-Content -Raw -Encoding UTF8 $snip)
      Add-Content -Path $agents -Value ([Environment]::NewLine + $body) -Encoding UTF8
      Write-Host "  已追加到 $agents"
    }
  }
}

$skillSrc = Join-Path $Here 'skill\desktop-control.md'
$skillDst = Join-Path $env:USERPROFILE '.memory\skills\desktop-control.md'
if ((Test-Path $skillSrc) -and (Test-Path (Split-Path -Parent $skillDst))) {
  Copy-Item -Force $skillSrc $skillDst
  Write-Host "  已复制技能页到 $skillDst"
}

if ($Plugin) {
  Say "注册成 DSH 插件"
  $dsh = Get-Command dsh -ErrorAction SilentlyContinue
  if (-not $dsh) {
    Write-Host "  没找到 dsh 命令。请在 DSH 自带的终端里执行：" -ForegroundColor Yellow
    Write-Host ("    dsh plugin --profile " + $Profile + " add link:" + $Here)
  } else {
    & dsh plugin --profile $Profile add ("link:" + $Here)
    if ($LASTEXITCODE -eq 0) { Write-Host "  已注册，重启 DSH 后会出现 desktop 工具" } else { Write-Host "  注册失败，见上面的输出" -ForegroundColor Yellow }
  }
}

if (-not $SkipTest) {
  Say "端到端自检（会弹一个记事本，几秒后自动关掉）"
  try {
    Dctl selftest
    if ($LASTEXITCODE -ne 0) { throw "selftest 退出码 $LASTEXITCODE" }
  } catch {
    Write-Host ""
    Write-Host "  自检没过：$($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  照 docs\TUTORIAL-windows.md 的「排错」一节逐条查。"
    exit 1
  }
}

Write-Host ""
Write-Host "装好了。" -ForegroundColor Green
Write-Host "  1. 新开一个终端，敲 dctl apps 看窗口列表"
Write-Host "  2. 想截图按 Win+PrtSc（Windows 自带，存到 图片\屏幕截图），或用 dctl shot"
Write-Host "  3. 让 DSH 用上：装成插件（-Plugin），或留着 AGENTS 准则让 agent 直接调 dctl"
