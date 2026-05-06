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
