# DeltaFStation 卸载脚本
# 仅移除 NSSM 注册的 Windows 服务；代码 / venv / data / nginx 都保留
#
# Usage:
#   PS> .\deploy\windows\uninstall.ps1

param(
  [string]$NssmPath    = "C:\nssm\nssm.exe",
  [string]$ServiceName = "DeltaFStation"
)

$ErrorActionPreference = "Stop"

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
  Write-Host "服务 $ServiceName 不存在, 无需卸载" -ForegroundColor DarkGray
  exit 0
}

Write-Host "Stopping $ServiceName ..." -ForegroundColor Yellow
& $NssmPath stop $ServiceName | Out-Null

Write-Host "Removing $ServiceName ..." -ForegroundColor Yellow
& $NssmPath remove $ServiceName confirm | Out-Null

Write-Host "✓ 服务 $ServiceName 已卸载 (代码/venv/data/nginx 均保留)" -ForegroundColor Green
