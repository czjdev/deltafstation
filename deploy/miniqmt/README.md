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

打开浏览器：`http://<公网IP>:18081`

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
