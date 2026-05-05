# DeltaFStation 云服务器部署设计 (Windows Server 2022 + 天翼云)

- 日期：2026-05-05
- 状态：待实施
- 参考：`/Users/chenzhijie/Documents/tq_option_system2/deploy/`（结构对齐其 Windows 主线，但裁剪 DB / Vue SPA / 鉴权相关步骤）

## 1. 背景与约束

### 1.1 项目现状（盘点）
- **Web 框架**：Flask 2.3 + Jinja templates（**非 SPA**，前端 HTML 由 Flask 渲染，无 `npm run build`）
- **入口**：`run.py` → `backend.app:create_app()`，默认监听 `0.0.0.0:5000`
- **存储**：纯文件，**无数据库**。`data/{raw,results,strategies,simulations}` + `logs/`
- **后台线程**：`backend/app.py:97` `live_data_manager.start()` 在 `create_app()` 内启动，进程内拉行情
- **SSE 长连**：
  - `/api/logs/stream`（`backend/app.py:132`）依赖**进程内**全局 `LogQueue`
  - `/api/ai/*` LLM 流式回答
- **鉴权**：**完全没有**。所有 API（含下单、AI 调用）裸暴露
- **敏感配置**：`config/config.py:12` 硬编码 DeepSeek API key `sk-aa5be...`
- **可选实盘**：miniQMT（仅 Windows，需 QMT 客户端登录 + xtquant SDK）

### 1.2 用户决策（已确认）
| 维度 | 选择 |
|---|---|
| 目标 OS | Windows Server 2022 |
| 云厂商 | 天翼云 |
| 域名 / HTTPS | 无域名 → HTTP + 端口换 18080 |
| 访问控制 | nginx Basic Auth |
| miniQMT 实盘 | 启用 |
| 代码源 | git clone `git@github.com:czjdev/deltafstation.git`（私有仓库 + SSH deploy key）|
| 部署形态 | nginx 反代 + waitress + NSSM 注册 Windows 服务（方案 ①）|

### 1.3 显式不做（YAGNI）
- ❌ Linux systemd / Linux nginx 配置
- ❌ Docker / docker-compose
- ❌ PostgreSQL / alembic / seed_admin（项目无 DB / 无登录）
- ❌ 前端 build（无 SPA）
- ❌ HTTPS / Let's Encrypt（无域名做不了；README 留口子）
- ❌ 多环境 dev/staging/prod
- ❌ 自动化 CI/CD（一台机器手动 `upgrade.ps1` 够用）
- ❌ 抽 `.env` / 改 `config/config.py`（保持现状，README 给可选指引）

## 2. 架构

```
                            天翼云 Windows Server 2022
                            公网 IP: <YOUR_PUBLIC_IP>

         [浏览器]                               [安全组放行]
            │                                    TCP 18080
            │  http://<IP>:18080/...
            │  Authorization: Basic <base64>
            ▼
     ┌──────────────────────────────────────────────┐
     │  nginx for Windows                           │
     │  C:\nginx\conf\nginx.conf                    │
     │   • listen 18080                             │
     │   • auth_basic + .htpasswd                   │
     │   • location /        → 反代 127.0.0.1:8000  │
     │   • location /api/logs/stream → SSE          │
     │     proxy_buffering off                      │
     │   • location /api/ai/  → SSE 同上            │
     └──────────────────────────────────────────────┘
                       │
                       ▼ 127.0.0.1:8000 (内网回环, 不对外)
     ┌──────────────────────────────────────────────┐
     │  waitress (单进程 4 线程)                    │
     │  服务名: DeltaFStation (NSSM 注册, 开机自启) │
     │  WorkingDir: C:\deltafstation                │
     │  ExecStart: .venv\Scripts\waitress-serve.exe │
     │              --listen=127.0.0.1:8000         │
     │              --threads=4                     │
     │              --call backend.app:create_app   │
     │  Stdout/Stderr → C:\deltafstation\logs\      │
     │  AppExit Default Restart (崩溃 5s 自愈)      │
     └──────────────────────────────────────────────┘
                       │
        ┌──────────────┼─────────────────────┐
        ▼              ▼                     ▼
   [LiveDataMgr]   [Flask Routes]      [LLM/SSE/Backtest]
   后台线程         /api/data/...       OpenAI 兼容 → DeepSeek
   yfinance         /api/strategies/    流式 SSE
   miniQMT 行情     /api/broker/  ─────────┐
                                           │
                                           ▼
                          ┌──────────────────────────────┐
                          │  QMT 客户端 (单独 GUI 进程)  │
                          │  C:\国金证券QMT交易端\        │
                          │  必须保持登录 + 后台运行      │
                          │  xtquant SDK 进程间通信      │
                          └──────────────────────────────┘
```

### 2.1 关键不变量
1. **单进程多线程**：`live_data_manager` 在 `create_app()` 启动后台线程；`/api/logs/stream` 依赖**进程内**全局 `LogQueue`。多 worker 会让行情重复拉取、SSE 找不到主进程
2. **waitress 仅监听 127.0.0.1**：不对外，必须经 nginx
3. **SSE 端点必须关 nginx buffering**（`/api/logs/stream`、`/api/ai/`），否则前端拿不到流
4. **QMT 客户端在同一台机器**：xtquant 走本机进程间通信，不开额外网络口

## 3. 目录布局

仓库根新增：

```
deltafstation/
├── deploy/
│   ├── README.md                # 主部署文档（手把手中文）
│   ├── windows/
│   │   ├── install.ps1          # 一键安装
│   │   ├── upgrade.ps1          # 升级
│   │   ├── uninstall.ps1        # 卸载
│   │   ├── nginx.conf           # nginx for Windows 配置
│   │   └── gen-htpasswd.ps1     # 生成 .htpasswd
│   └── miniqmt/
│       └── README.md            # QMT 客户端 + xtquant 安装指引
├── requirements.txt             # 追加 waitress>=3.0.0
└── .gitignore                   # 追加 .env（未来抽 secret 备用）
```

**不动的文件**：`backend/`、`frontend/`、`config/`、`run.py`、`start.sh`（保留本地启动方式不影响老用户）

## 4. install.ps1 设计

### 4.1 参数
```powershell
param(
  [string]$ProjectRoot   = "C:\deltafstation",
  [string]$NssmPath      = "C:\nssm\nssm.exe",
  [string]$PythonExe     = "python.exe",
  [string]$ServiceName   = "DeltaFStation",
  [int]$WaitressPort     = 8000,
  [int]$WaitressThreads  = 4
)
```

### 4.2 步骤
1. `Set-Location $ProjectRoot`
2. 创建 venv（不存在才建）：`python -m venv .venv`
3. `pip install --upgrade pip` → `pip install -r requirements.txt`
4. 创建运行时目录：`data\raw`、`data\results`、`data\strategies`、`data\simulations`、`logs`（对齐 `start.sh:28`）
5. 检测 `xtquant`，未安装则提示走 `deploy\miniqmt\README.md`
6. 卸载旧服务（幂等）：若 `sc.exe query DeltaFStation` 存在则 stop + remove
7. NSSM 注册 `DeltaFStation`：
   - exe：`.venv\Scripts\waitress-serve.exe`
   - args：`--listen=127.0.0.1:8000 --threads=4 --call backend.app:create_app`
   - `AppDirectory`：`$ProjectRoot`
   - `AppEnvironmentExtra`：`PYTHONUNBUFFERED=1` `FLASK_ENV=production`
   - `Start`：`SERVICE_AUTO_START`
   - `AppStdout` / `AppStderr`：`logs\server-stdout.log` / `logs\server-stderr.log`
   - `AppRotateFiles` `1` + `AppRotateOnline` `1` + `AppRotateBytes` `10485760`（10MB 轮转）
   - `AppExit Default Restart` + `AppRestartDelay 5000`（崩溃 5s 自愈）
8. NSSM start
9. 末尾打印下一步：配 nginx → 生成 .htpasswd → 安全组放行 18080 → 浏览器访问

### 4.3 与 tq2 install.ps1 的差异
- 砍 `alembic upgrade head`（无 DB）
- 砍 `seed_admin.py`（无登录）
- 砍 `npm install && npm run build`（无 SPA）
- 加 `xtquant` 检测提示
- 加日志轮转 + 崩溃自愈（tq2 没有）

## 5. nginx.conf 设计

### 5.1 关键配置
- `listen 18080`
- `auth_basic "DeltaFStation"` + `auth_basic_user_file C:/nginx/conf/.htpasswd`（**正斜杠**，Windows nginx 要求）
- `client_max_body_size 50M`
- `proxy_http_version 1.1` + `proxy_set_header Connection ""`（HTTP/1.1 chunked 透传）

### 5.2 location 划分
| location | 反代 | 特殊设置 |
|---|---|---|
| `/` | `http://127.0.0.1:8000` | 默认；`Host`、`X-Real-IP`、`X-Forwarded-For`、`X-Forwarded-Proto` |
| `/api/logs/stream` | `http://127.0.0.1:8000` | `proxy_buffering off; proxy_cache off; proxy_read_timeout 24h; chunked_transfer_encoding on` |
| `/api/ai/` | `http://127.0.0.1:8000` | `proxy_buffering off; proxy_cache off; proxy_read_timeout 600s` |

### 5.3 nginx 也注册成 Windows 自启服务
nginx for Windows 默认不开机自启。在 `deploy/README.md` step 4 末尾给出 NSSM 注册 nginx 的命令（不放进 install.ps1，避免对 nginx 安装路径强假设）：
```powershell
& C:\nssm\nssm.exe install nginx        C:\nginx\nginx.exe
& C:\nssm\nssm.exe set     nginx AppDirectory C:\nginx
& C:\nssm\nssm.exe set     nginx Start         SERVICE_AUTO_START
& C:\nssm\nssm.exe start   nginx
```
（保证 `Get-Service DeltaFStation, nginx` 都是 Running，重启服务器后自动恢复）

### 5.4 与 tq2 nginx.conf 的差异
| 维度 | tq2 | deltafstation |
|---|---|---|
| 端口 | 80 | **18080** |
| Basic Auth | 无 | **有** |
| 前端服务 | `root C:/.../frontend/dist; try_files` 直出 Vue SPA | **全部反代** Flask（Jinja 渲染 + send_static_file）|
| 流式接口 | `/ws/`（WebSocket）| `/api/logs/stream` + `/api/ai/`（SSE，关 buffering）|

**为什么不让 nginx 直出 `/static/*`**：deltafstation 单人/少量人用，Flask `send_static_file` 完全够。让 nginx 直出要写绝对路径，Windows 上 `\` vs `/` 易踩坑，权衡下来全反代更稳。未来高并发再优化。

## 6. upgrade.ps1 / uninstall.ps1 / gen-htpasswd.ps1

### 6.1 upgrade.ps1
```
NSSM stop → git pull → pip install -r requirements.txt → NSSM start
```
（不需要 alembic、不需要 npm build，比 tq2 更轻）

### 6.2 uninstall.ps1
```
NSSM stop → NSSM remove confirm
```
代码不删；nginx / venv / data 都保留。

### 6.3 gen-htpasswd.ps1
- `Read-Host -Prompt "用户名"` + `Read-Host -AsSecureString -Prompt "密码（≥20 字符）"`
- 强制密码长度 ≥ 20，否则报错退出
- 用 .NET `System.Security.Cryptography` 生成 SHA1 + base64 hash（nginx Windows 版支持 `{SHA}` 前缀的 .htpasswd 行）
- 写到 `C:\nginx\conf\.htpasswd`，格式 `<user>:{SHA}<base64-sha1>`
- 提示用户 `nginx -s reload` 生效

## 7. miniQMT 配置（deploy/miniqmt/README.md）

### 7.1 流程
1. 下载 + 安装 QMT 客户端（国金/银河/华泰极速版/广发等任选）
2. 登录 QMT（**先打券商客服报备云服务器公网 IP，避免异地登录风控锁号**）
3. 拷贝 xtquant SDK 到 venv：
   ```powershell
   $qmtPath  = "C:\国金证券QMT交易端\bin.x64\Lib\site-packages\xtquant"
   $venvPath = "C:\deltafstation\.venv\Lib\site-packages\xtquant"
   Copy-Item -Recurse -Force $qmtPath $venvPath
   ```
4. 验证：`.\.venv\Scripts\python.exe -c "from xtquant import xttrader; print('ok')"`
5. 浏览器进入主页 → 数据源切 miniQMT → 拉一根 K 线测试 → 交易页切 broker 模式 → 1 手 ETF 小额测试
6. QMT 开机自启（可选）：`shell:startup` 文件夹放快捷方式（QMT 是 GUI 应用，**不能**用 NSSM 注册）

### 7.2 异常
- "异地登录"被踢：联系券商客服解绑 + 报备新 IP
- QMT 崩溃：deltafstation `broker_engine` 断连，重启 QMT + 主页重新点 connect
- 行情延迟：检查 QMT 自身行情是否正常（QMT 需订阅行情权限）

## 8. README.md（deploy/README.md）章节

```
0. 前置软件清单（一次安装）
1. 配置 GitHub SSH Deploy Key
2. 拉代码 (git clone git@github.com:czjdev/deltafstation.git)
3. 一键安装服务 (.\deploy\windows\install.ps1)
4. 配置 nginx 反代（含用 NSSM 把 nginx 也注册成自启服务）
5. Windows 防火墙 + 天翼云安全组放行 18080
6. 验证
7. miniQMT 实盘配置（可选 → 引导到 deploy/miniqmt/README.md）
8. 升级 / 卸载
9. 安全建议
10. 故障排查
```

## 9. 安全建议

1. **revoke 老 LLM key** —— `config/config.py:12` 的 `sk-aa5be...` 已在 git 历史和聊天里出现，部署前必须吊销 + 换新 key
2. **强 Basic Auth 密码** —— `gen-htpasswd.ps1` 强制 ≥20 字符，避免暴力破解
3. **服务端口 18080**，**安全组只放 18080**，Flask:8000 / QMT 内部端口都不对外
4. **天翼云 RDP 端口改非 3389**（Windows 远程桌面是被扫得最猛的入口）
5. **QMT 客户端机器锁屏**：离开服务器要锁屏，避免 QMT 窗口被远程桌面看到/操作
6. **logs 目录定期清理**：NSSM 已配 10MB 日志轮转；`data/results` 需自行归档
7. **未来加 HTTPS**：申请域名 + win-acme → Let's Encrypt（README 留口子，本期不做）

## 10. 故障排查

| 现象 | 排查 |
|---|---|
| 服务启不来 | `Get-Service DeltaFStation` + `Get-Content C:\deltafstation\logs\server-stderr.log -Tail 100` |
| 浏览器 502 | `C:\nginx\logs\error.log` + `netstat -an \| findstr 8000` 确认 waitress 在监听 |
| 401 一直弹密码框 | 确认 `.htpasswd` 路径用正斜杠 `C:/nginx/conf/.htpasswd`，重跑 `gen-htpasswd.ps1` |
| 公网访问不通 | (1) `Get-NetFirewallRule -DisplayName "DeltaFStation HTTP"` (2) 天翼云控制台安全组入站 TCP/18080 |
| SSE 日志/AI 流卡住 | nginx.conf 里 SSE location 是否 `proxy_buffering off` |
| miniQMT 数据拉不到 | QMT 客户端是否登录 + xtquant 是否拷到 venv + 异地登录是否解锁 |
| pip 装包慢/失败 | 临时换源 `pip install -i https://pypi.tuna.tsinghua.edu.cn/simple ...` |
| `git pull` 401 | SSH deploy key 配错或权限不足，重新生成 + 加到 GitHub |
| 服务突然停 | `Get-EventLog -LogName Application -Newest 50`；NSSM 已配崩溃 5s 自愈 |

## 11. 实施顺序（写实施 plan 时拆 step）

1. 在仓库根加 `deploy/` 骨架（空目录 + 占位 README）
2. `requirements.txt` 追加 `waitress>=3.0.0`；`.gitignore` 追加 `.env`
3. 写 `deploy/windows/install.ps1`
4. 写 `deploy/windows/upgrade.ps1` + `uninstall.ps1`
5. 写 `deploy/windows/nginx.conf`
6. 写 `deploy/windows/gen-htpasswd.ps1`
7. 写 `deploy/miniqmt/README.md`
8. 写 `deploy/README.md`（主文档，含上述 0-10 节）
9. （脱机）本地用 PowerShell 静态语法检查 `Get-Command -Syntax`、用 `nginx -t` 验证 conf
10. commit

## 12. 验收标准

- 在天翼云 Windows Server 2022 上从 0 开始，按 `deploy/README.md` 走完，能看到：
  - 浏览器 `http://<公网IP>:18080` 弹 Basic Auth 密码框
  - 输入密码后看到 DeltaFStation 主页
  - SSE 日志流实时刷新
  - AI Agent 对话流式输出
  - （启用 miniQMT 后）能拉 A 股 K 线 + 下 1 手 ETF 测试单
- 重启云服务器后服务自动恢复
- `upgrade.ps1` 一次成功完成升级流程
