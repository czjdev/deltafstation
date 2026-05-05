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
2. **强 Basic Auth 密码** —— `gen-htpasswd.ps1` 强制 ≥20 字符；用 `[Convert]::ToBase64String((New-Object byte[] 24 | %{[byte](Get-Random -Max 256)}))` 生成随机串
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
