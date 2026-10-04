# frp for fly.io - 部署说明

一套安全、开箱即用的 frp (frps) 服务端部署方案，专为 fly.io 平台优化。
所有敏感凭证通过 `fly secrets` 注入，**无需硬编码密码**，可安全提交到公开仓库。

---

## 📁 文件结构

```
frp-flyio/
├── Dockerfile          # frps 镜像构建文件
├── frps.toml           # frps 配置文件（使用环境变量占位符）
├── fly.toml            # fly.io 应用部署配置
├── frpc-example.toml   # 客户端配置示例
├── .dockerignore
├── .gitignore
└── README.md
```

---

## 🚀 快速部署

### 1. 前置准备
- 安装 flyctl: `curl -L https://fly.io/install.sh | sh`
- 登录 fly.io: `fly auth login`

### 2. 初始化应用（首次部署）

```bash
# 进入项目目录
cd frp-flyio

# 初始化 fly 应用（按提示操作，建议先不要部署）
fly launch
# 提示是否部署时选择 No，先配置密钥
```

如果 `fly launch` 自动覆盖了 `fly.toml`，请参考仓库中的 `fly.toml` 修改端口配置。

### 3. 设置敏感密钥（重要！）

**不要将真实密码写入 `frps.toml`**，通过以下命令设置（会被加密存储，不会入库）：

```bash
# 生成并设置 frp 认证 Token（建议使用强随机字符串）
fly secrets set FRP_AUTH_TOKEN="请替换为一个32位以上的随机字符串"

# 设置仪表盘登录用户名和密码
fly secrets set FRP_DASHBOARD_USER="admin"
fly secrets set FRP_DASHBOARD_PWD="请替换为你的仪表盘强密码"
```

> 提示：你可以用 `openssl rand -hex 16` 快速生成一个安全的随机 Token。

### 4. 部署到 fly.io

```bash
fly deploy
```

### 5. 验证部署

```bash
# 查看应用状态
fly status

# 查看实时日志
fly logs
```

---

## 📊 访问仪表盘

部署成功后，通过浏览器访问仪表盘：

```
https://你的应用名.fly.dev
```
（如果 7500 端口配置了 tls handler，会自动走 HTTPS）

登录时使用你通过 `fly secrets set FRP_DASHBOARD_USER` 和 `FRP_DASHBOARD_PWD` 设置的账号密码。

---

## 💻 客户端配置 (frpc)

在你需要内网穿透的机器上，编辑 `frpc.toml`：

```toml
serverAddr = "你的应用名.fly.dev"
serverPort = 7000

auth.method = "token"
auth.token = "你在 FRP_AUTH_TOKEN 中设置的那个值"

# 示例：穿透本地 SSH
[[proxies]]
name = "ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = 6022
```

> ⚠️ 注意：使用 `remotePort` 时，你需要在 `fly.toml` 中添加对应端口的 `[[services]]` 配置，然后重新 `fly deploy`。
> 否则该端口在 fly.io 外部是不可达的。本仓库的 `fly.toml` 中已给出注释示例。

启动客户端：
```bash
./frpc -c frpc.toml
```

然后通过 `ssh -p 6022 用户名@你的应用名.fly.dev` 即可连接内网机器。

---

## 🔧 常用运维命令

| 命令 | 作用 |
| :--- | :--- |
| `fly logs` | 查看实时日志 |
| `fly status` | 查看实例状态 |
| `fly secrets list` | 查看已设置的密钥列表（仅显示名称） |
| `fly secrets set KEY=value` | 更新/添加密钥 |
| `fly deploy` | 重新部署（配置变更后） |
| `fly ssh console` | SSH 进入容器调试 |
| `fly apps destroy frp-server` | 删除应用（注意备份） |

---

## ⚠️ 注意事项

1. **区域选择**：`fly.toml` 中 `primary_region` 建议选择离你最近的区域以降低延迟：
   - `hkg` - 香港
   - `nrt` - 东京
   - `sin` - 新加坡
   - `sjc` - 美国圣何塞

2. **端口开放**：每增加一个需要公网访问的 `remotePort`，都必须在 `fly.toml` 的 `[[services]]` 中添加对应端口映射，然后重新部署。

3. **免费额度**：fly.io 免费计划包含 3 个共享 CPU 微型实例，但有网络流量限制。长期高流量使用请留意账单。

4. **自动休眠**：`auto_stop_machines` 已设为 `false`，避免 frp 长连接被中断。如果不需要 24 小时在线，可以改为 `true` 节省资源。

5. **安全**：
   - `FRP_AUTH_TOKEN` 务必设为强随机字符串
   - 仪表盘密码务必强密码
   - 不要将 `.env` 或含有真实密码的文件提交到 Git
