# DeltaFStation 升级脚本
# 流程: 停服务 → git pull → pip install → 启服务
#
# Usage:
#   PS> cd C:\deltafstation
#   PS> .\deploy\windows\upgrade.ps1

param(
  [string]$ProjectRoot = "C:\deltafstation",
  [string]$NssmPath    = "C:\nssm\nssm.exe",
  [string]$ServiceName = "DeltaFStation",
  [int]$WaitressPort   = 8000
)

$ErrorActionPreference = "Stop"

Set-Location $ProjectRoot

Write-Host "[1/4] Stopping $ServiceName ..." -ForegroundColor Yellow
& $NssmPath stop $ServiceName | Out-Null

Write-Host "[2/4] git pull ..." -ForegroundColor Yellow
git pull

Write-Host "[3/4] pip install -r requirements.txt ..." -ForegroundColor Yellow
& "$ProjectRoot\.venv\Scripts\pip.exe" install -r requirements.txt

Write-Host "[4/4] Starting $ServiceName ..." -ForegroundColor Yellow
& $NssmPath start $ServiceName

# 等 waitress 实际绑定端口（仅看 SCM Running 不够，因为 NSSM 崩溃重启循环也会瞬时 Running）
$deadline = (Get-Date).AddSeconds(15)
$bound = $false
while ((Get-Date) -lt $deadline) {
  $tnc = Test-NetConnection -ComputerName 127.0.0.1 -Port $WaitressPort `
            -InformationLevel Quiet -WarningAction SilentlyContinue
  if ($tnc) { $bound = $true; break }
  Start-Sleep -Milliseconds 500
}
if (-not $bound) {
  Write-Host "❌ 服务未在 15s 内监听 127.0.0.1:$WaitressPort" -ForegroundColor Red
  Write-Host "   排查: Get-Content $ProjectRoot\logs\server-stderr.log -Tail 50" -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "✓ 升级完成" -ForegroundColor Green
