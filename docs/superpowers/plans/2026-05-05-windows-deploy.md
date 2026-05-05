# DeltaFStation Windows 部署 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 deltafstation 仓库根新增 `deploy/` 目录，提供 Windows Server 2022 + 天翼云的一键部署脚本（waitress + NSSM + nginx + Basic Auth）和 miniQMT 实盘配置文档。

**Architecture:** nginx (18080, Basic Auth) → waitress (127.0.0.1:8000, 单进程 4 线程) → Flask app；NSSM 把 waitress 注册成 Windows 服务 `DeltaFStation`，崩溃 5s 自愈、日志 10MB 轮转。

**Tech Stack:** PowerShell 5.1+, NSSM 2.24+, nginx for Windows, waitress 3.0+, Python 3.11+, xtquant (miniQMT 实盘可选)

**Spec:** [`docs/superpowers/specs/2026-05-05-windows-deploy-design.md`](../specs/2026-05-05-windows-deploy-design.md)

**Constraints:**
- 在 macOS 上无法端到端测 PowerShell + NSSM + nginx for Windows，本地验证只到"文件结构 + 关键字 grep"层面；端到端验证靠 Task 9 的云服务器 checklist
- 所有脚本要求**幂等**（同一脚本多次跑结果一致），install.ps1 重跑要能覆盖旧服务而非报错
- 不动 `backend/`、`frontend/`、`config/`、`run.py`、`start.sh`（保持本地 dev 启动方式）

---

## File Structure

新增 / 修改的文件：

| 路径 | 状态 | 行数估 | 责任 |
|---|---|---|---|
| `requirements.txt` | 修改（追加 1 行）| - | 加生产 WSGI `waitress>=3.0.0` |
| `deploy/windows/install.ps1` | 新建 | ~95 | venv + pip + NSSM 注册 `DeltaFStation` 服务 + 启动 |
| `deploy/windows/upgrade.ps1` | 新建 | ~30 | NSSM stop → git pull → pip → NSSM start |
| `deploy/windows/uninstall.ps1` | 新建 | ~20 | NSSM stop + remove；代码不删 |
| `deploy/windows/nginx.conf` | 新建 | ~70 | listen 18080 + Basic Auth + 反代 + SSE 关 buffering |
| `deploy/windows/gen-htpasswd.ps1` | 新建 | ~50 | PowerShell 计算 SHA1 写 `C:\nginx\conf\.htpasswd` |
| `deploy/miniqmt/README.md` | 新建 | ~80 | QMT 客户端安装、xtquant 拷贝、券商风控提示 |
| `deploy/README.md` | 新建 | ~170 | 主部署文档（10 节：前置、克隆、安装、nginx、防火墙、验证、QMT、升级卸载、安全、排查）|

文件依赖：`deploy/README.md` 引用其他所有文件名/路径，所以**最后写**（避免引用不存在的文件名）。

---

## Task 1: 追加 waitress 依赖

**Files:**
- Modify: `requirements.txt:32`

- [ ] **Step 1: 在 requirements.txt 末尾追加 waitress**

将以下行追加到 `requirements.txt` 末尾（紧跟 `deltafq>=1.0.2` 之后，不要加在 `# Project core` 之前）：

```
deltafq>=1.0.2

# Production WSGI server (Windows-friendly, used by deploy/windows/install.ps1)
waitress>=3.0.0
```

注意：保留原 `deltafq>=1.0.2` 行不变；仅在文件末尾追加空行 + 注释 + waitress 行。

- [ ] **Step 2: 验证 waitress 出现在文件末尾**

```bash
tail -3 requirements.txt
```
Expected 输出包含 `waitress>=3.0.0`。

- [ ] **Step 3: Commit**

```bash
git add requirements.txt
git commit -m "deps: 新增生产 WSGI waitress 依赖（部署用）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: 写 deploy/windows/install.ps1

**Files:**
- Create: `deploy/windows/install.ps1`

- [ ] **Step 1: 创建 install.ps1（完整内容）**

写入以下完整内容到 `deploy/windows/install.ps1`：

```powershell
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
  [int]$WaitressPort     = 8000,
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
Write-Host "  4. Windows 防火墙 + 天翼云安全组放行 18080"
Write-Host "  5. 浏览器访问 http://<公网IP>:18080"
```

- [ ] **Step 2: 文件级验证（关键字 + 行数）**

```bash
wc -l deploy/windows/install.ps1
grep -c "NssmPath\|waitress-serve\|AppRotateFiles\|SERVICE_AUTO_START" deploy/windows/install.ps1
```
Expected：行数约 130（含端口探测块）；关键字命中数 ≥ 4。

- [ ] **Step 3: Commit**

```bash
git add deploy/windows/install.ps1
git commit -m "deploy: 新增 install.ps1 (venv + NSSM 注册 DeltaFStation 服务)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: 写 deploy/windows/upgrade.ps1

**Files:**
- Create: `deploy/windows/upgrade.ps1`

- [ ] **Step 1: 创建 upgrade.ps1（完整内容）**

写入以下完整内容到 `deploy/windows/upgrade.ps1`：

```powershell
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

# 升级中断时打印恢复命令（不自动重启，避免掩盖真实失败原因）
trap {
  Write-Host ""
  Write-Host "⚠️ 升级中断: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "   服务可能停止; 恢复: & '$NssmPath' start $ServiceName" -ForegroundColor Yellow
  exit 1
}

Set-Location $ProjectRoot

# 防止未提交改动 / merge conflict 让 pull 静默失败
$dirty = git status --porcelain
if ($dirty) {
  throw "工作目录有未提交改动, 请先提交或 git stash:`n$dirty"
}

Write-Host "[1/4] Stopping $ServiceName ..." -ForegroundColor Yellow
& $NssmPath stop $ServiceName | Out-Null

Write-Host "[2/4] git pull --ff-only ..." -ForegroundColor Yellow
git pull --ff-only
if ($LASTEXITCODE -ne 0) { throw "git pull 失败 (可能 merge conflict)" }

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
```

- [ ] **Step 2: 文件级验证**

```bash
wc -l deploy/windows/upgrade.ps1
grep -E "NssmPath stop|git pull|pip install|NssmPath start" deploy/windows/upgrade.ps1
```
Expected：行数约 62（含 trap + 脏检查 + 端口探测）；4 个关键字各命中 1 行。

- [ ] **Step 3: Commit**

```bash
git add deploy/windows/upgrade.ps1
git commit -m "deploy: 新增 upgrade.ps1 (停服务 + git pull + pip + 启服务)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 写 deploy/windows/uninstall.ps1

**Files:**
- Create: `deploy/windows/uninstall.ps1`

- [ ] **Step 1: 创建 uninstall.ps1（完整内容）**

写入以下完整内容到 `deploy/windows/uninstall.ps1`：

```powershell
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
```

- [ ] **Step 2: 文件级验证**

```bash
wc -l deploy/windows/uninstall.ps1
grep -E "NssmPath stop|NssmPath remove" deploy/windows/uninstall.ps1
```
Expected：行数约 25；2 关键字各命中 1 行。

- [ ] **Step 3: Commit**

```bash
git add deploy/windows/uninstall.ps1
git commit -m "deploy: 新增 uninstall.ps1 (移除 NSSM 服务, 代码保留)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: 写 deploy/windows/nginx.conf

**Files:**
- Create: `deploy/windows/nginx.conf`

- [ ] **Step 1: 创建 nginx.conf（完整内容）**

写入以下完整内容到 `deploy/windows/nginx.conf`：

```nginx
# DeltaFStation nginx for Windows 配置
# 部署: Copy-Item deploy\windows\nginx.conf C:\nginx\conf\nginx.conf
# 应用: cd C:\nginx; .\nginx.exe -s reload
#
# 关键差异 vs tq2:
#   - 端口 18080 (避免被全网扫描器自动探测)
#   - Basic Auth (gen-htpasswd.ps1 生成 .htpasswd)
#   - 全部反代 Flask, 不让 nginx 直出 /static/* (deltafstation 是 Jinja templates, 非 SPA)
#   - SSE 端点关 buffering (/api/logs/stream + /api/ai/)

worker_processes  auto;

events {
    worker_connections  1024;
}

http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile      on;
    keepalive_timeout 65;
    gzip on;

    # HTTP/1.1 chunked 透传 (SSE 必备)
    proxy_http_version 1.1;
    proxy_set_header   Connection "";

    server {
        listen 18080;
        server_name _;

        client_max_body_size 50M;

        # Basic Auth (gen-htpasswd.ps1 生成)
        # 注意: Windows 路径用正斜杠
        auth_basic           "DeltaFStation";
        auth_basic_user_file C:/nginx/conf/.htpasswd;

        # 通用安全响应头
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options        "DENY"    always;
        add_header X-XSS-Protection       "1; mode=block" always;

        # SSE: 实时日志流 (/api/logs/stream)
        # 必须先于通用 / 出现, 否则被 / 抢走
        location = /api/logs/stream {
            proxy_pass                http://127.0.0.1:8000;
            proxy_buffering           off;
            proxy_cache               off;
            proxy_read_timeout        24h;
            chunked_transfer_encoding on;
            proxy_set_header          Host              $host;
            proxy_set_header          X-Real-IP         $remote_addr;
            proxy_set_header          X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header          X-Forwarded-Proto $scheme;
        }

        # SSE: AI Agent 流式回答 (/api/ai/*)
        location /api/ai/ {
            proxy_pass         http://127.0.0.1:8000;
            proxy_buffering    off;
            proxy_cache        off;
            proxy_read_timeout 600s;
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
        }

        # 默认: 全部反代 waitress
        # (前端 HTML/static 都由 Flask 渲染/返回, 不让 nginx 直出)
        location / {
            proxy_pass         http://127.0.0.1:8000;
            proxy_set_header   Host              $host;
            proxy_set_header   X-Real-IP         $remote_addr;
            proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header   X-Forwarded-Proto $scheme;
            proxy_read_timeout 60s;
        }
    }
}
```

- [ ] **Step 2: 文件级验证**

```bash
wc -l deploy/windows/nginx.conf
grep -cE "listen 18080|auth_basic|proxy_buffering off|proxy_pass.*127\.0\.0\.1:8000" deploy/windows/nginx.conf
```
Expected：行数约 70；4 关键字总命中 ≥ 6（auth_basic 出现 2 次、proxy_pass 出现 3 次、proxy_buffering off 出现 2 次、listen 出现 1 次）。

- [ ] **Step 3: Commit**

```bash
git add deploy/windows/nginx.conf
git commit -m "deploy: 新增 nginx.conf (端口 18080 + Basic Auth + SSE)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 写 deploy/windows/gen-htpasswd.ps1

**Files:**
- Create: `deploy/windows/gen-htpasswd.ps1`

- [ ] **Step 1: 创建 gen-htpasswd.ps1（完整内容）**

写入以下完整内容到 `deploy/windows/gen-htpasswd.ps1`：

```powershell
# 生成 nginx Basic Auth 密码文件 .htpasswd
# 用 PowerShell 内置 .NET API, 不依赖 Apache htpasswd.exe
# 输出格式: <user>:{SHA}<base64-of-sha1-of-password>  (nginx for Windows 支持)
#
# Usage:
#   PS> .\deploy\windows\gen-htpasswd.ps1
#   PS> .\deploy\windows\gen-htpasswd.ps1 -OutputPath "C:\nginx\conf\.htpasswd"

param(
  [string]$OutputPath  = "C:\nginx\conf\.htpasswd",
  [int]$MinPasswordLen = 20
)

$ErrorActionPreference = "Stop"

Write-Host "=== DeltaFStation Basic Auth 密码生成 ===" -ForegroundColor Cyan
Write-Host "输出文件: $OutputPath"
Write-Host ""

$user = Read-Host -Prompt "用户名 (英数字, 不含冒号)"
if ([string]::IsNullOrWhiteSpace($user) -or $user.Contains(":")) {
  throw "用户名不能为空或包含冒号"
}

$securePwd = Read-Host -Prompt "密码 (要求长度 >= $MinPasswordLen)" -AsSecureString
$bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePwd)
try {
  $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
} finally {
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}

if ($plain.Length -lt $MinPasswordLen) {
  throw "密码长度 $($plain.Length) < $MinPasswordLen ；HTTP 下 Basic Auth 是明文, 请用更长的随机密码"
}

# 计算 SHA1 + base64 (nginx 接受 {SHA} 前缀)
$sha1   = [System.Security.Cryptography.SHA1]::Create()
$bytes  = [System.Text.Encoding]::UTF8.GetBytes($plain)
$hash   = $sha1.ComputeHash($bytes)
$sha1.Dispose()
$base64 = [Convert]::ToBase64String($hash)

$line = "${user}:{SHA}${base64}"

# 确保目录存在
$dir = Split-Path -Parent $OutputPath
if (-not (Test-Path $dir)) {
  throw "目录不存在: $dir ；先安装 nginx 到 C:\nginx"
}

# 写文件 (覆盖) - 注意不要 BOM, nginx 解析 .htpasswd 不接受 BOM
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($OutputPath, "$line`n", $utf8NoBom)

# 限制 .htpasswd ACL: 只允许 SYSTEM + Administrators (防本机其他账户读 hash)
try {
  & icacls $OutputPath /grant:r 'SYSTEM:(F)' 'Administrators:(F)' /inheritance:r 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "⚠️ icacls 设置失败 (exit $LASTEXITCODE), 文件仍按父目录默认权限" -ForegroundColor Yellow
  }
} catch {
  Write-Host "⚠️ ACL 限制失败: $_" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✓ 已写入 $OutputPath" -ForegroundColor Green
Write-Host "  内容: ${user}:{SHA}<hash>"
Write-Host ""
Write-Host "下一步: cd C:\nginx; .\nginx.exe -s reload" -ForegroundColor Cyan
```

- [ ] **Step 2: 文件级验证**

```bash
wc -l deploy/windows/gen-htpasswd.ps1
grep -E "Read-Host|SHA1|base64|MinPasswordLen|UTF8" deploy/windows/gen-htpasswd.ps1
```
Expected：行数约 50；5 关键字各至少命中 1 次。

- [ ] **Step 3: Commit**

```bash
git add deploy/windows/gen-htpasswd.ps1
git commit -m "deploy: 新增 gen-htpasswd.ps1 (PowerShell 生成 nginx Basic Auth 密码文件)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: 写 deploy/miniqmt/README.md

**Files:**
- Create: `deploy/miniqmt/README.md`

- [ ] **Step 1: 创建 miniqmt/README.md（完整内容）**

写入以下完整内容到 `deploy/miniqmt/README.md`：

```markdown
# miniQMT 实盘配置（Windows）

DeltaFStation 的实盘交易（`broker_api` / `broker_engine`）依赖券商 QMT 客户端 + `xtquant` Python SDK。本文档指导你在云服务器上把 miniQMT 跑起来并和 deltafstation 联通。

## 1. 下载并安装 QMT 客户端

挑一家支持 QMT 的券商，下载其 QMT 极速版客户端，安装到默认路径：

| 券商 | 下载地址 | 默认安装路径 |
|---|---|---|
| 国金证券 | 营业部官网或 App 下载 QMT | `C:\国金证券QMT交易端\` |
| 银河证券 | 同上 | `C:\银河证券QMT交易端\` |
| 华泰证券 | 同上 | `C:\华泰证券MATIC\` |
| 广发证券 | 同上 | `C:\广发证券极速版\` |

> ⚠️ 不同券商路径不同，下面的命令以**国金**为例，请按你装的券商替换路径。

## 2. 登录 QMT（重要：先报备 IP）

**云服务器跨地域登录会触发券商风控**，导致：
- 账号被锁
- 强制短信/视频认证
- 资金账户被冻结

**部署前必做**：
1. 打券商客服电话，告知"我要在云服务器上跑 QMT 客户端"
2. 报备**云服务器公网 IP**（让客服把这个 IP 加到你的常用登录白名单）
3. 拿到客服工号 + 备案回执（出问题时可申诉）

报备完成后才登录 QMT：
1. 启动 QMT 客户端
2. 输入资金账号 + 交易密码 + 通讯密码
3. 登录成功后**保持窗口运行**（最小化即可，**不能关**），否则 deltafstation 调不到

## 3. 拷贝 xtquant SDK 到 venv

xtquant 不通过 pip 发布，必须从 QMT 安装目录手动拷贝到 deltafstation 的 venv：

```powershell
# 管理员 PowerShell
$qmtPath  = "C:\国金证券QMT交易端\bin.x64\Lib\site-packages\xtquant"
$venvPath = "C:\deltafstation\.venv\Lib\site-packages\xtquant"

if (-not (Test-Path $qmtPath)) {
  throw "找不到源路径: $qmtPath ；请按你装的券商修改路径"
}

Copy-Item -Recurse -Force $qmtPath $venvPath
Write-Host "✓ xtquant 已拷贝到 $venvPath"
```

## 4. 验证 xtquant 可调

```powershell
cd C:\deltafstation
.\.venv\Scripts\python.exe -c "from xtquant import xttrader; print('xtquant ok')"
```

期望输出：`xtquant ok`

如果报 `ImportError: DLL load failed`，多半是 QMT 客户端路径下的 dll 没加到 PATH，参考券商 QMT 文档配置 `bin.x64` 到系统 PATH。

## 5. 在 deltafstation 中切换数据源 + 实盘

打开浏览器：`http://<公网IP>:18080`

1. **数据源**：主页右上角数据源切换为 `miniqmt`，拉一根 A 股 K 线测试
2. **实盘交易**：交易页 → broker 模式 → connect → 选个低价 ETF（比如 159915 创业板）下 1 手 100 元以内的小单 → 看是否成交
3. 撤单 / 查持仓 / 查资金都点一遍

如果走通，再放心跑你的策略。

## 6. QMT 开机自启（可选）

QMT 客户端是 GUI 应用，**不能用 NSSM 注册成 Windows 服务**（因为 NSSM 会拿不到登录凭据，且 GUI 在 session 0 不可见）。

让 QMT 在登录后自动启动：
1. `Win + R` 输入 `shell:startup` 回车
2. 把 QMT 客户端快捷方式拖进去
3. 之后只要 RDP 登录到云服务器，QMT 自动启动

> 注意：云服务器重启 → 你必须 RDP 登录一次（或开启自动登录），QMT 才会启动。如果服务器无人值守长跑，要么开 Windows 自动登录（有安全风险），要么定期 RDP 检查。

## 7. 常见异常

| 现象 | 原因 / 处理 |
|---|---|
| QMT 登录提示"异地登录" | 没报备 IP；联系券商解绑 + 重新报备 |
| QMT 登录后过几小时被踢 | 券商风控；联系客服延长会话或加白名单 |
| `from xtquant import ...` ImportError | xtquant 没拷到 venv；或 dll 路径问题（见 step 4）|
| deltafstation 主页 broker connect 失败 | QMT 客户端是否在前台跑 + 是否登录 + 资金账号是否对 |
| 行情数据延迟严重 | QMT 自身行情订阅是否正常 (检查 QMT 行情面板) |
| 下单报"未授权交易品种" | 券商账户没开权限 (如可转债/创业板/科创板要单独开通) |
| 重启服务器后 QMT 没起来 | 用 `shell:startup` 加自启 + 配 Windows 自动登录 (慎重) |

## 8. 安全提醒

- QMT 资金密码 + 通讯密码**绝不**写到任何脚本或 config 里；只在 QMT 客户端 GUI 输入
- 云服务器 RDP 端口改非 3389（避免暴力破解）
- 离开服务器记得锁屏（避免有人偷偷操作 QMT）
- 单笔下单金额建议在 deltafstation 策略层加上限保护（避免 bug 一次梭哈）
```

- [ ] **Step 2: 文件级验证**

```bash
wc -l deploy/miniqmt/README.md
grep -cE "xtquant|风控|shell:startup|broker connect" deploy/miniqmt/README.md
```
Expected：行数约 90；4 关键字总命中 ≥ 5。

- [ ] **Step 3: Commit**

```bash
git add deploy/miniqmt/README.md
git commit -m "deploy: 新增 miniQMT 配置文档 (券商风控报备 + xtquant 拷贝 + 异常排查)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: 写 deploy/README.md（主部署文档）

**Files:**
- Create: `deploy/README.md`

- [ ] **Step 1: 创建 deploy/README.md（完整内容）**

写入以下完整内容到 `deploy/README.md`：

````markdown
# DeltaFStation 部署（Windows Server 2022 + 天翼云）

把 deltafstation 跑到天翼云 Windows Server 2022 上的手把手指南。架构 / 决策见 [`docs/superpowers/specs/2026-05-05-windows-deploy-design.md`](../docs/superpowers/specs/2026-05-05-windows-deploy-design.md)。

> Linux 部署不在本期范围；如需自行参考 tq_option_system2/deploy/。

## 0. 前置软件清单（每台机器装一次）

| 软件 | 版本 | 下载 | 说明 |
|---|---|---|---|
| Python | 3.11+ | https://www.python.org/downloads/ | 安装时勾 ☑ Add to PATH |
| Git for Windows | latest | https://git-scm.com/download/win | 安装后会自带 ssh-keygen |
| nginx for Windows | latest | http://nginx.org/en/download.html | 解压到 `C:\nginx` |
| NSSM | 2.24+ | https://nssm.cc/download | 解压后把 `nssm.exe` 放到 `C:\nssm\nssm.exe` |

## 1. 配置 GitHub SSH Deploy Key

云服务器上：

```powershell
# 生成 SSH key (一路回车, 不设密码方便服务器自动 git pull)
ssh-keygen -t ed25519 -C "deltafstation-server" -f $HOME\.ssh\id_ed25519

# 复制公钥到剪贴板
Get-Content $HOME\.ssh\id_ed25519.pub | Set-Clipboard
```

打开 https://github.com/czjdev/deltafstation/settings/keys/new
- Title: `deltafstation-cloud-server`
- Key: 粘贴公钥
- ☑ Allow write access（不勾也行，只读够用）
- 点 **Add key**

测试：

```powershell
ssh -T git@github.com
# Hi czjdev! You've successfully authenticated, but GitHub does not provide shell access.
```

## 2. 拉代码

```powershell
cd C:\
git clone git@github.com:czjdev/deltafstation.git
cd C:\deltafstation
```

## 3. 一键安装服务

```powershell
# 必须管理员 PowerShell
.\deploy\windows\install.ps1
```

脚本会：
1. 创建 `.venv`
2. `pip install -r requirements.txt`（含新加的 `waitress`）
3. 创建 `data\{raw,results,strategies,simulations}` 和 `logs` 目录
4. 检测 `xtquant`（没装的话只是提示，不阻断）
5. 用 NSSM 注册 Windows 服务 `DeltaFStation`，开机自启 + 崩溃 5s 自愈 + 日志 10MB 轮转
6. 启动服务并校验 Running

成功后，`Get-Service DeltaFStation` 应显示 Running。

## 4. 配置 nginx 反代 + Basic Auth

```powershell
# 复制 nginx 配置
Copy-Item .\deploy\windows\nginx.conf C:\nginx\conf\nginx.conf

# 生成 Basic Auth 密码文件 (会要求输入用户名 + ≥20 字符的密码)
.\deploy\windows\gen-htpasswd.ps1

# 启动 nginx
cd C:\nginx
.\nginx.exe                      # 首次启动
# 后续修改配置后:
# .\nginx.exe -s reload

# 用 NSSM 把 nginx 也注册成 Windows 自启服务 (重启服务器后自动恢复)
& C:\nssm\nssm.exe install nginx        C:\nginx\nginx.exe
& C:\nssm\nssm.exe set     nginx AppDirectory C:\nginx
& C:\nssm\nssm.exe set     nginx Start         SERVICE_AUTO_START
& C:\nssm\nssm.exe start   nginx
```

> 注意：直接 `.\nginx.exe` 启动的 nginx 是裸进程，关掉 PowerShell 不会自动停，但**重启服务器不会自动起**。所以最后一步 NSSM 注册必做。

## 5. Windows 防火墙 + 天翼云安全组

### 5.1 Windows 防火墙

```powershell
New-NetFirewallRule -DisplayName "DeltaFStation HTTP" `
    -Direction Inbound -Protocol TCP -LocalPort 18080 -Action Allow
```

### 5.2 天翼云控制台安全组

登录天翼云控制台 → 你的云服务器 → 安全组 → 配置规则 → 入站规则
- 协议：TCP
- 端口：18080
- 源 IP：`0.0.0.0/0`（如果你想再收紧，填你的固定办公/家庭 IP/32）
- 描述：DeltaFStation HTTP

> ⚠️ 不要再额外开放 8000（waitress）或其他内部端口，只开 18080。

## 6. 验证

```
浏览器 → http://<云服务器公网IP>:18080
→ 弹出 Basic Auth 密码框
→ 输入 step 4 设置的用户名/密码
→ 看到 DeltaFStation 主页
```

冒烟测试：
1. 数据中心 → 拉一只股票 K 线
2. AI Agent → 问个问题（看流式回答是否实时输出）
3. 监控页 → 日志流是否实时刷新
4. 如果配了 miniQMT，进交易页测下单

## 7. miniQMT 实盘配置（可选）

见 [`deploy/miniqmt/README.md`](miniqmt/README.md)

## 8. 升级 / 卸载

### 升级

```powershell
cd C:\deltafstation
.\deploy\windows\upgrade.ps1
```

脚本会：停 `DeltaFStation` 服务 → `git pull` → `pip install -r requirements.txt` → 启服务。

### 卸载（仅移除 Windows 服务，代码 / venv / data / nginx 都保留）

```powershell
.\deploy\windows\uninstall.ps1
```

如果你要彻底清理：
```powershell
# 移除 nginx 服务
& C:\nssm\nssm.exe stop   nginx
& C:\nssm\nssm.exe remove nginx confirm
# 删代码 (谨慎)
Remove-Item -Recurse -Force C:\deltafstation
```

## 9. 安全建议

1. **第一时间 revoke 老 LLM key** —— `config/config.py:12` 硬编码的 DeepSeek key `sk-aa5be...` 已在 git 历史和聊天里出现。部署前去 [DeepSeek 控制台](https://platform.deepseek.com/api_keys) 吊销旧 key + 生成新 key 替换
2. **强 Basic Auth 密码** —— `gen-htpasswd.ps1` 强制 ≥20 字符；用 `[Convert]::ToBase64String((New-Object byte[] 24 \| %{[byte](Get-Random -Max 256)}))` 生成随机串
3. **服务端口 18080 + 安全组只放 18080** —— Flask:8000 / QMT 内部端口都不对外
4. **天翼云 RDP 端口改非 3389** —— Windows 远程桌面是被扫得最猛的入口
5. **QMT 客户端机器锁屏** —— 离开服务器要锁屏，避免 QMT 窗口被 RDP 偷看/操作
6. **logs 目录定期清理** —— NSSM 已配 10MB 日志轮转；回测产物 `data/results/*.json` 自己定期归档
7. **未来加 HTTPS** —— 申请域名（一年十几块）+ [win-acme](https://www.win-acme.com/) 一键 Let's Encrypt（本期不做）

## 10. 故障排查

| 现象 | 排查命令 / 文件 |
|---|---|
| `Get-Service DeltaFStation` 显示 Stopped | `Get-Content C:\deltafstation\logs\server-stderr.log -Tail 100` 看错误；多半是 venv 装包失败或端口占用 |
| 浏览器 502 Bad Gateway | (1) `Get-Content C:\nginx\logs\error.log -Tail 50` (2) `netstat -an \| findstr 8000` 确认 waitress 在监听 |
| 401 一直弹密码框 | (1) `.htpasswd` 路径必须用正斜杠 `C:/nginx/conf/.htpasswd`（nginx.conf 第 22 行附近）(2) 重跑 `gen-htpasswd.ps1` 重新写一次 |
| 公网访问不通 | (1) `Get-NetFirewallRule -DisplayName "DeltaFStation HTTP"` (2) 天翼云控制台安全组入站 TCP/18080 是否开 (3) 公网 IP 是否对（云服务器面板查一下）|
| SSE 日志/AI 流卡住不刷 | nginx.conf 里 SSE 两个 location（`/api/logs/stream` 和 `/api/ai/`）是否都有 `proxy_buffering off` |
| miniQMT 数据拉不到 | (1) QMT 客户端是否登录中 (2) `xtquant` 是否在 `.venv\Lib\site-packages\xtquant` (3) 异地登录是否解锁 |
| pip 装包慢 / 失败 | 临时换源：`pip install -i https://pypi.tuna.tsinghua.edu.cn/simple -r requirements.txt` |
| `git pull` 报 401 | SSH deploy key 配错 / 被删；重新跑 step 1 |
| 服务跑着突然停 | (1) `Get-EventLog -LogName Application -Newest 50` (2) NSSM 已配 `AppExit Default Restart`，正常 5s 后自愈 |
| `waitress-serve.exe` 不存在 | venv 装包失败：`.\.venv\Scripts\pip.exe install waitress` 单独装一下 |

## 附录：架构图

```
浏览器 → http://<IP>:18080 (Basic Auth)
    ↓
nginx (C:\nginx, 服务名 nginx)
    ↓ http://127.0.0.1:8000
waitress (服务名 DeltaFStation)
    ↓
Flask app (backend.app:create_app)
    ├→ live_data_manager (后台线程)
    ├→ /api/data/*, /api/strategies/*, ...
    ├→ /api/logs/stream (SSE)
    ├→ /api/ai/* (LLM SSE → DeepSeek)
    └→ /api/broker/* → xtquant → QMT 客户端 (单独 GUI 进程)
```
````

- [ ] **Step 2: 文件级验证**

```bash
wc -l deploy/README.md
grep -cE "install\.ps1|upgrade\.ps1|uninstall\.ps1|nginx\.conf|gen-htpasswd\.ps1|miniqmt/README\.md" deploy/README.md
```
Expected：行数约 175；6 个文件名各被引用 ≥ 1 次（总命中 ≥ 8）。

- [ ] **Step 3: Commit**

```bash
git add deploy/README.md
git commit -m "deploy: 新增主部署文档 (10 节: 前置 + 克隆 + 安装 + nginx + 防火墙 + 验证 + QMT + 升级卸载 + 安全 + 排查)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: 端到端验证 checklist（云服务器手动）

**Files:**
- 无新增；只是把验证清单产出给用户

本地 macOS 无法跑 Windows + NSSM + nginx + miniQMT，所以最终验证必须在云服务器上手动完成。

- [ ] **Step 1: 给用户一份手动验收清单**

打印以下 checklist 给用户，让用户在天翼云上按 `deploy/README.md` 走完后逐项打勾：

```
=== DeltaFStation 云服务器部署验收 checklist ===

A. 前置 (deploy/README.md step 0)
  [ ] Python 3.11+ 装好且 `python --version` 正常
  [ ] Git for Windows 装好且 `git --version` 正常
  [ ] nginx 解压到 C:\nginx 且 C:\nginx\nginx.exe 存在
  [ ] NSSM 解压到 C:\nssm 且 C:\nssm\nssm.exe 存在

B. 代码 + 服务 (step 1-3)
  [ ] GitHub SSH key 配好, ssh -T git@github.com 通过
  [ ] git clone 到 C:\deltafstation 成功
  [ ] install.ps1 跑完, 末尾打印 ✓ DeltaFStation 服务已启动
  [ ] Get-Service DeltaFStation 显示 Running
  [ ] netstat -an | findstr 8000 看到 127.0.0.1:8000 LISTENING

C. nginx + Basic Auth (step 4)
  [ ] nginx.conf 拷到 C:\nginx\conf\nginx.conf
  [ ] gen-htpasswd.ps1 生成 .htpasswd 成功
  [ ] nginx 启动 (.\nginx.exe), 没报错
  [ ] nginx 也用 NSSM 注册成服务, Get-Service nginx 显示 Running

D. 防火墙 + 安全组 (step 5)
  [ ] Get-NetFirewallRule -DisplayName "DeltaFStation HTTP" 存在
  [ ] 天翼云控制台安全组 TCP/18080 入站已放行

E. 浏览器验收 (step 6)
  [ ] 浏览器 http://<公网IP>:18080 弹出密码框
  [ ] 输入正确密码 → 看到 DeltaFStation 主页
  [ ] 输入错误密码 → 401 拒绝
  [ ] 数据中心拉一只股票 K 线 → 正常显示
  [ ] AI Agent 问一个问题 → 流式实时输出 (不是一次性出现)
  [ ] 监控页日志流 → 实时刷新

F. miniQMT 实盘 (step 7, deploy/miniqmt/README.md)
  [ ] 已联系券商客服报备云服务器公网 IP
  [ ] QMT 客户端登录成功并保持后台运行
  [ ] xtquant 已拷到 C:\deltafstation\.venv\Lib\site-packages\xtquant
  [ ] python -c "from xtquant import xttrader; print('ok')" 输出 ok
  [ ] deltafstation 主页数据源切 miniqmt → 拉 K 线成功
  [ ] 交易页 broker connect → 下 1 手低价 ETF 测试单 → 成交

G. 自愈 / 升级 / 卸载
  [ ] 手动停服务 (nssm stop DeltaFStation), 5s 后看日志是否自动重启
  [ ] 重启云服务器 → 重启后 Get-Service DeltaFStation 仍 Running
  [ ] 重启云服务器 → Get-Service nginx 仍 Running
  [ ] 浏览器仍能访问 http://<IP>:18080
  [ ] 在仓库改个无关文件 push 到 main, upgrade.ps1 跑完后服务仍 Running

H. 安全 (step 9)
  [ ] DeepSeek 控制台已 revoke 老 key sk-aa5be...
  [ ] config/config.py:12 已换新 key 并重新部署 (重跑 install.ps1 末尾的 nssm restart)
  [ ] Basic Auth 密码长度 ≥ 20 字符且随机
  [ ] RDP 端口已改成非 3389
```

- [ ] **Step 2: （在云服务器上完成验收后）汇报结果**

让用户回报：
- 哪些项✓
- 哪些项✗（卡住的话连同错误信息一起发回，按 deploy/README.md step 10 故障排查表对照）

---

## Self-Review

**1. Spec coverage**

| Spec section | Covered by |
|---|---|
| §1 背景与约束 | （背景, 不需 task）|
| §2 架构 | Task 8 (deploy/README.md 附录架构图) |
| §3 目录布局 | Task 1-8 共同实现 |
| §4 install.ps1 | Task 2 |
| §5.1-5.2 nginx.conf 配置 + location | Task 5 |
| §5.3 nginx 注册自启服务 | Task 8 (deploy/README.md step 4 末尾 NSSM 命令) |
| §5.4 与 tq2 差异 | Task 5 文件头注释 + Task 8 注解 |
| §6.1 upgrade.ps1 | Task 3 |
| §6.2 uninstall.ps1 | Task 4 |
| §6.3 gen-htpasswd.ps1 | Task 6 |
| §7 miniQMT | Task 7 |
| §8 README.md 章节 | Task 8 |
| §9 安全建议 | Task 8 (deploy/README.md §9) |
| §10 故障排查 | Task 8 (deploy/README.md §10) |
| §11 实施顺序 | 即本 plan 的 task 顺序 |
| §12 验收标准 | Task 9 |

✓ 全覆盖。

**2. Placeholder scan** — 已检 grep TBD/TODO/占位/FIXME/XXX，无命中。

**3. Type / 一致性 check**

- 服务名 `DeltaFStation`：跨 Task 2/3/4/8/9 均一致
- 端口 `18080`（外）/ `8000`（内）：Task 2/5/8/9 均一致
- waitress 启动参数 `--listen=127.0.0.1:8000 --threads=4 --call backend.app:create_app`：Task 2 install.ps1 + Task 8 README 附录均一致
- 文件路径 `C:\deltafstation` / `C:\nginx\conf\nginx.conf` / `C:/nginx/conf/.htpasswd`（正斜杠）/ `C:\nssm\nssm.exe`：跨 task 一致
- NSSM 命令参数（`AppDirectory`、`AppRotateBytes`、`AppExit Default Restart`）：Task 2 install.ps1 完整设置；Task 3/4 只引用服务名

✓ 一致。

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-05-windows-deploy.md`. Two execution options:**

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
