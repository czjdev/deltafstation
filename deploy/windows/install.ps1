# DeltaFStation Windows Server 2022 一键安装脚本
# 在管理员 PowerShell 中运行
#
# 前置（自行安装）:
#   - Python 3.11+ (官方 installer + Add to PATH)
#   - Git for Windows (并配好 GitHub SSH deploy key)
#   - nginx for Windows (解压到 C:\nginx)
#   - NSSM 2.24+ (解压到 C:\nssm)
#
# Usage:
#   PS> cd C:\deltafstation
#   PS> .\deploy\windows\install.ps1

param(
  [string]$ProjectRoot   = "C:\deltafstation",
  [string]$NssmPath      = "C:\nssm\nssm.exe",
  [string]$PythonExe     = "python.exe",
  [string]$ServiceName   = "DeltaFStation",
  [int]$WaitressPort     = 8001,
  [int]$WaitressThreads  = 4
)

$ErrorActionPreference = "Stop"

Write-Host "=== DeltaFStation Windows install ===" -ForegroundColor Cyan
Write-Host "ProjectRoot   = $ProjectRoot"
Write-Host "ServiceName   = $ServiceName"
Write-Host "WaitressPort  = $WaitressPort (内网回环, 不对外)"
Write-Host ""

# 1. 进入项目目录
if (-not (Test-Path $ProjectRoot)) {
  throw "项目目录不存在: $ProjectRoot ；先 git clone 到该路径"
}
Set-Location $ProjectRoot

# 2. 创建 venv (不存在才建)
if (-not (Test-Path "$ProjectRoot\.venv")) {
  Write-Host "[1/7] 创建 venv ..." -ForegroundColor Yellow
  & $PythonExe -m venv .venv
} else {
  Write-Host "[1/7] venv 已存在, 跳过" -ForegroundColor DarkGray
}

# 3. 装依赖
Write-Host "[2/7] 升级 pip 并安装依赖 ..." -ForegroundColor Yellow
& "$ProjectRoot\.venv\Scripts\python.exe" -m pip install --upgrade pip
& "$ProjectRoot\.venv\Scripts\pip.exe" install -r requirements.txt

# 4. 创建运行时目录 (对齐 start.sh)
Write-Host "[3/7] 创建运行时目录 ..." -ForegroundColor Yellow
New-Item -ItemType Directory -Force -Path `
  "$ProjectRoot\data\raw", `
  "$ProjectRoot\data\results", `
  "$ProjectRoot\data\strategies", `
  "$ProjectRoot\data\simulations", `
  "$ProjectRoot\logs" | Out-Null

# 5. miniQMT 提示 (不强制)
Write-Host "[4/7] 检测 xtquant ..." -ForegroundColor Yellow
if (-not (Test-Path "$ProjectRoot\.venv\Lib\site-packages\xtquant")) {
  Write-Host "  ⚠️ 未检测到 xtquant；如需 miniQMT 实盘，请按 deploy\miniqmt\README.md 手动拷贝" -ForegroundColor Yellow
} else {
  Write-Host "  ✓ xtquant 已安装" -ForegroundColor Green
}

# 6. 校验 NSSM
if (-not (Test-Path $NssmPath)) {
  throw "NSSM 未找到: $NssmPath ；先下载 https://nssm.cc/download 解压到该路径"
}

# 7. 卸载旧服务 (幂等)
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
  Write-Host "[5/7] 已存在服务 $ServiceName, 先卸载 ..." -ForegroundColor Yellow
  & $NssmPath stop   $ServiceName | Out-Null
  & $NssmPath remove $ServiceName confirm | Out-Null
}

# 8. NSSM 注册新服务
Write-Host "[6/7] NSSM 注册服务 $ServiceName ..." -ForegroundColor Yellow
$waitressExe = "$ProjectRoot\.venv\Scripts\waitress-serve.exe"
$waitressArgs = "--listen=127.0.0.1:$WaitressPort --threads=$WaitressThreads --call backend.app:create_app"

& $NssmPath install $ServiceName $waitressExe $waitressArgs

& $NssmPath set $ServiceName AppDirectory        $ProjectRoot
& $NssmPath set $ServiceName AppEnvironmentExtra "PYTHONUNBUFFERED=1" "FLASK_ENV=production"
& $NssmPath set $ServiceName Start               SERVICE_AUTO_START

# 日志重定向 + 10MB 轮转
& $NssmPath set $ServiceName AppStdout       "$ProjectRoot\logs\server-stdout.log"
& $NssmPath set $ServiceName AppStderr       "$ProjectRoot\logs\server-stderr.log"
& $NssmPath set $ServiceName AppRotateFiles  1
& $NssmPath set $ServiceName AppRotateOnline 1
& $NssmPath set $ServiceName AppRotateBytes  10485760

# 崩溃 5s 自愈
& $NssmPath set $ServiceName AppExit Default Restart
& $NssmPath set $ServiceName AppRestartDelay 5000

# 9. 启动
Write-Host "[7/7] 启动服务 ..." -ForegroundColor Yellow
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
Write-Host "✓ DeltaFStation 服务已启动" -ForegroundColor Green
Write-Host ""
Write-Host "下一步:" -ForegroundColor Cyan
Write-Host "  1. 配置 nginx:"
Write-Host "     Copy-Item .\deploy\windows\nginx.conf C:\nginx\conf\nginx.conf"
Write-Host "  2. 生成 .htpasswd:"
Write-Host "     .\deploy\windows\gen-htpasswd.ps1"
Write-Host "  3. 启动 nginx 并注册成自启服务（命令见 deploy\README.md step 4）"
Write-Host "  4. Windows 防火墙 + 天翼云安全组放行 18081"
Write-Host "  5. 浏览器访问 http://<公网IP>:18081"
