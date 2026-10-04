# frp-flyio

把 [frp](https://github.com/fatedier/frp) 服务端（frps）一键部署到 [fly.io](https://fly.io)，
所有敏感凭证通过 `fly secrets` 注入，不硬编码进仓库，可放心公开。

## 📁 文件结构

```
frp-flyio/
├── Dockerfile             # 多阶段构建：下载 frps → 打包进最小 Alpine 镜像
├── entrypoint.sh          # 容器启动脚本：envsubst 注入环境变量后启动两个 frps 实例
├── frps.toml              # 主实例配置模板（TCP/HTTP/HTTPS，含 ${...} 占位符）
├── frps-udp.toml          # UDP 实例配置模板（绑 fly-global-services）
├── fly.toml               # fly.io 平台部署配置（端口、区域、健康检查）
├── frpc-example.toml      # 本地客户端配置示例（TCPMUX/TCP/HTTP/HTTPS/STCP/SUDP，连 7000）
├── frpc-udp-example.toml  # 本地客户端 UDP 配置示例（连 7001）
├── deploy.ps1             # Windows 一键发布脚本
├── add-port.ps1           # Windows 端口映射脚本（改 fly.toml + allowPorts）
├── .dockerignore
├── .gitignore
└── README.md
```

## ⚡ Windows 一键脚本（PowerShell）

| 脚本 | 作用 |
| :--- | :--- |
| `deploy.ps1` | 一键发布：查 flyctl → 查登录 → 建应用 → 补齐密钥 → 查 UDP 所需的独立 IPv4 → `fly deploy` → 看状态 |
| `add-port.ps1` | 映射端口：给 `fly.toml` 加 `[[services]]` 块 + 给 `frps*.toml` 的 `allowPorts` 加白名单，可 `-Deploy` 直接上线 |

```powershell
# 发布（缺失的密钥会逐个提示输入：Token 直接回车 = 自动生成随机值）
./deploy.ps1
./deploy.ps1 -RemoteOnly -Logs        # 用 fly.io 远程构建（本机无 Docker），发完跟日志
./deploy.ps1 -NoWait                  # 不等机器 healthy 就返回（健康检查卡住时用）
./deploy.ps1 -Token 'xxx' -DashboardUser admin -DashboardPwd 'yyy'   # 全程非交互

# 端口映射
./add-port.ps1 -List                                      # 查看当前映射
./add-port.ps1 -Protocol tcp   -StartPort 6005 -Count 5   # 加 TCP 6005-6009
./add-port.ps1 -Protocol udp   -StartPort 6105 -Count 5 -Deploy
./add-port.ps1 -Protocol http  -StartPort 8085 -Count 5 -Deploy
```

> 脚本已存为 UTF-8 with BOM，Windows PowerShell 5.1 / PowerShell 7 都能正常显示中文。
> 若提示禁止运行脚本：`Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`。
>
> **关于健康检查**：`fly.toml` 里用的是 frps 仪表盘的 `/healthz`（免鉴权，直接返回 200）。
> 别改成 `/static/` —— 它在鉴权子路由里，没登录返回 401，机器会永远 unhealthy，
> 导致 `fly deploy` / `fly secrets set` 一直卡在 `Waiting for ... to become healthy`。
> 密钥用 `fly secrets set --stage` 只暂存不重启，避免旧机器健康不过时卡死。

## 🔢 端口规划

服务端开放 **4 组 × 5 个连续端口**（外部端口 = 容器内部端口，frps 直接监听同名端口）：

| 协议 | 端口 | frpc 用法 | 访问方式 |
| :--- | :--- | :--- | :--- |
| TCP | `6000-6004` | `type = "tcp"`，`remotePort = 6000..6004` | `域名:6000` |
| UDP | `6100-6104` | `type = "udp"`，`remotePort = 6100..6104`（连 7001 实例） | `域名:6100` |
| HTTP | `8080-8084` | `8080`：`type = "http"` + `customDomains`（按域名路由）<br>`8081-8084`：`type = "tcp"` | `http://域名:8080` |
| HTTPS | `8443-8447` | `8443`：`type = "https"` + `customDomains`（按域名路由）<br>`8444-8447`：`type = "tcp"` | `https://域名:8443` |
| TCPMUX | `8333` | `type = "tcpmux"` + `multiplexer = "httpconnect"`（按域名路由） | `curl -x http://域名:8333 https://目标` |
| STCP / SUDP | 无公网端口 | `type = "stcp"` / `"sudp"` + `secretKey`，访问方配 `[[visitors]]` | 本地 `127.0.0.1:visitor 端口` |

控制端口：`7000` 主实例（TCP / HTTP / HTTPS / TCPMUX / STCP / SUDP）、`7001` UDP 实例，仪表盘在主实例 `7500`（经 `https://应用名.fly.dev` 访问）。

> `8333` 是 frps 的 `tcpmuxHTTPConnectPort`，像 vhost 一样按域名路由，**不占 `remotePort`**，不受 `allowPorts` 限制。
> STCP / SUDP 走的是 frpc 已建立的控制连接（7000），**服务端不需要任何额外端口**，改客户端配置即可用。

> frps 的 vhost 端口各只能有一个（`vhostHTTPPort` / `vhostHTTPSPort`），
> 所以每组第 1 个端口给 vhost 做域名路由，其余 4 个作为裸 TCP 端口用 `type = "tcp"` 承载 HTTP/HTTPS 流量。

## ✅ 实测状态（当前实例 `frp-tidy-coral-6267`）

2026-10-04 从公网实测：

| 项目 | 结果 |
| :--- | :--- |
| 应用 / 区域 | `frp-tidy-coral-6267` / `sin`，共享 CPU 1x、256MB |
| TCP 端口（22 个） | `7000`、`7001`、`6000-6004`、`8080-8084`、`8443-8447` 全部可连（本次新增的 `8333` 待下次 `fly deploy` 后复测） |
| `https://域名/healthz` | `200` → 机器 healthy，健康检查通过 |
| `https://域名/` | `401` → 仪表盘鉴权生效 |
| `http://域名:8080/` | `404` → frps 的 vhost 路由在响应，确认跑的是新镜像 |
| UDP `6100-6104` | 边缘已开放；但要 frpc 注册 udp 代理后 frps 才会监听 |

> 穿透端口（6000-6004 等）是 **frpc 注册后 frps 才动态监听** 的，
> 没有客户端时用 `nc` 测会「连上即断开」，属正常现象，不是端口没开。

## 🚀 快速部署

### 1. 前置准备

- 安装 flyctl：`curl -L https://fly.io/install.sh | sh`
- 登录：`fly auth login`
- 克隆本仓库并进入目录：
  ```bash
  git clone https://github.com/yejinlei/frp-flyio.git
  cd frp-flyio
  ```

### 2. 初始化应用（首次）

```bash
fly launch
```

出现以下提示时这样选：

- **Would you like to copy its configuration to the new app?** → `Y`（复用现有 fly.toml）
- **Choose an app name** → 输入你喜欢的名字（如 `my-frp-server`），会生成 `my-frp-server.fly.dev`
- **Choose a region** → 选离你近的（推荐 hkg/nrt/sin）
- **Would you like to set up a Postgresql database?** → `N`
- **Would you like to set up an Upstash Redis database?** → `N`
- **Would you like to deploy now?** → **`N`**（先设置密钥再部署）

### 3. 设置敏感密钥（重要！）

```bash
# 生成一个随机 Token 作为客户端连接凭证
fly secrets set FRP_AUTH_TOKEN="$(openssl rand -hex 16)"

# 仪表盘用户名（可选，默认 admin，已在 fly.toml 里配）
# fly secrets set FRP_DASHBOARD_USER="admin"

# 仪表盘登录密码（必填，改成你自己的强密码）
fly secrets set FRP_DASHBOARD_PWD="YourStrongPassword123!"
```

> 这些密钥不会进入代码仓库、不会显示在日志中，由 fly.io 加密存储、启动时注入容器。

### 4. 申请独立 IPv4（UDP 必需）

fly.io 上 **UDP 只支持独立 IPv4**，共享 IPv4 和 IPv6 都不行（TCP 两种都行）：

```bash
fly ips allocate-v4        # 独立 IPv4，约 $2/月
fly ips list               # 确认已分配
```

> 只用 TCP/HTTP/HTTPS、不用 UDP 的话可以跳过这步，
> 也可以把 `fly.toml` 里的 5 个 UDP `[[services]]` 块删掉。

### 5. 部署

```bash
fly deploy
```

等待镜像构建与推送完成（首次约 1~2 分钟）。

Windows 上更推荐用脚本，密钥缺失时会**逐个提示输入**：

```powershell
./deploy.ps1 -RemoteOnly
```

> 仓库自带 `.github/workflows/fly-deploy.yml`：push 到 `main` 会自动触发
> `flyctl deploy --remote-only`。需要在 GitHub 仓库 Settings → Secrets 里配 `FLY_API_TOKEN`
> （`fly tokens create deploy -a 应用名` 生成），没配的话该 workflow 会失败，不影响手动部署。

### 6. 验证部署

```bash
# 查看实例状态（应显示 1 running）
fly status

# 查看实时日志，正常应该看到两个实例：
# "start frps success"  "frps tcp listen on 0.0.0.0:7000"   ← 主实例
# "Dashboard listen on 0.0.0.0:7500"
# "start frps success"  "frps tcp listen on 0.0.0.0:7001"   ← UDP 实例
fly logs

# 端口连通性自检（把域名换成你自己的）
nc -vz 你的应用名.fly.dev 7000     # 主实例控制端口
nc -vz 你的应用名.fly.dev 7001     # UDP 实例控制端口
nc -vzu 你的应用名.fly.dev 6100    # UDP 穿透端口（frpc 起来后才有响应）
```

## 📊 访问仪表盘

部署成功后，浏览器打开：

```
https://你的应用名.fly.dev
```

用你设置的用户名/密码登录（默认用户名 `admin`，密码为 `FRP_DASHBOARD_PWD`）。
可以看到当前连接的客户端和每个代理的流量情况。

## 💻 客户端配置 (frpc)

1. 在本地下载对应平台的 [frp 客户端](https://github.com/fatedier/frp/releases)
2. 复制仓库里的 `frpc-example.toml` 为 `frpc.toml`，修改：
   - `serverAddr` → 你的 `你的应用名.fly.dev`
   - `auth.token` → 和服务端 `FRP_AUTH_TOKEN` 完全相同
3. 启动客户端：
   ```bash
   ./frpc -c frpc.toml
   ```
4. 以 SSH 为例，穿透成功后在任意机器执行即可连回你的内网机器：
   ```bash
   ssh -p 6000 用户名@你的应用名.fly.dev
   ```

### UDP 穿透（单独一个 frpc 进程）

UDP 必须连服务端的 **7001** 端口（UDP 专用 frps 实例），而 frpc 一个配置文件只能填一个
`serverPort`，所以 UDP 要另开一个配置文件、单独起一个进程：

```bash
cp frpc-udp-example.toml frpc-udp.toml   # 改 serverAddr / auth.token
./frpc -c frpc-udp.toml
```

### TCPMUX 穿透（共用 8333 一个端口）

`frps.toml` 已开 `tcpmuxHTTPConnectPort = 8333`。与 HTTP vhost 类似按域名路由，
因此**多个 tcpmux 代理可以共用一个 8333 端口**，也不占用 `remotePort`：

```toml
[[proxies]]
name = "tcpmux-dev"
type = "tcpmux"
multiplexer = "httpconnect"
localIP = "127.0.0.1"
localPort = 3000
customDomains = ["dev.your-domain.com"]   # 需解析到你的 fly 应用
```

使用时把 8333 当 HTTP CONNECT 代理即可：

```bash
curl -x http://dev.your-domain.com:8333 https://example.com/
```

### STCP / SUDP（不需要服务端开端口）

适合 SSH、数据库这类只让指定人访问的服务：公网上不留任何端口，
流量走 frpc 已建立的控制连接（7000），靠 `secretKey` 鉴权。

内网机（被访问方）：

```toml
[[proxies]]
name = "secret-ssh"
type = "stcp"               # SUDP 用 "sudp"
secretKey = "换成一串够长的随机串"
localIP = "127.0.0.1"
localPort = 22
```

访问方再起一个 frpc（配 `[[visitors]]`）：

```toml
[[visitors]]
name = "secret-ssh-visitor"
type = "stcp"
serverName = "secret-ssh"
secretKey = "同上"
bindAddr = "127.0.0.1"
bindPort = 6000             # 本地端口，随便选
```

然后 `ssh -p 6000 用户名@127.0.0.1`。SUDP 同理，但注意两端 `udpPacketSize` 保持一致（默认 1500）。

### ⚠️ 新增端口必须做的事

现在服务端只放行白名单端口（`frps.toml` / `frps-udp.toml` 里的 `allowPorts`）：
TCP `6000-6004`、UDP `6100-6104`、HTTP `8081-8084`、HTTPS `8444-8447`。
要新增端口必须**同时改三处**，否则连不上：

1. `fly.toml`：加一个 `[[services]]` 块（外部端口和 `internal_port` 保持一致）；
2. `frps.toml`（或 `frps-udp.toml`）：把新端口加进 `allowPorts`；
3. `fly deploy` 重新部署。

> 注意 `8080` / `8443` 已被 vhost 占用、`8333` 已被 tcpmux 占用，都不能再当 `remotePort` 用。
> TCPMUX、STCP、SUDP 例外：它们不走 `allowPorts`，不需要加白名单。

## 🔧 常用运维命令

| 命令 | 作用 |
| :--- | :--- |
| `fly logs` | 查看实时日志 |
| `fly status` | 查看实例状态 |
| `fly secrets list` | 查看已设置的密钥列表（仅显示名称，不显示值） |
| `fly secrets set KEY=value` | 更新/添加密钥（设置后自动重启） |
| `fly deploy` | 重新部署（配置变更后执行） |
| `fly ssh console` | SSH 进入容器调试 |
| `fly apps destroy 你的应用名` | 删除应用（注意备份） |

## ⚠️ 注意事项

- **内存**：当前 `fly.toml` 配的是 256MB（共享 CPU 最低档），容器内跑两个 frps 进程。
  若 `fly logs` 里出现 OOM，执行 `fly scale memory 512` 并同步改 `fly.toml` 的 `[[vm]]`（否则下次 deploy 会被覆盖回 256MB）。
- **免费额度**：fly.io 免费套餐包含 3 个共享 CPU 机器 + 160GB 出站流量/月，足够个人使用。
  长时间无流量的实例可能被自动暂停，本配置已设置 `auto_stop_machines = false` 保持长连。
- **版本一致**：本地 `frpc` 版本应与 Dockerfile 中的 `FRP_VERSION` 一致（默认 0.62.0），避免协议不兼容。
- **UDP 为什么是两个 frps**：fly.io 要求 UDP 绑 `fly-global-services`、TCP 绑 `0.0.0.0`，
  而 frps 的 `proxyBindAddr` 只能填一个，所以容器里跑两个实例（7000 主 / 7001 UDP）。
  UDP 不通时先查：`fly ssh console` → `getent hosts fly-global-services`。
- **UDP 包大小**：fly.io 隧道会占用几十字节，UDP 单包建议 ≤ 1300 字节，必要时调小本端 MTU。
- **安全**：务必使用强 Token 和仪表盘密码，不要使用 123456 等弱口令。
- **密钥轮换**：如怀疑泄露，执行 `fly secrets set FRP_AUTH_TOKEN="新值"` 后客户端同步更新即可。
