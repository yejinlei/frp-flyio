# frp-flyio

把 [frp](https://github.com/fatedier/frp) 服务端（frps）一键部署到 [fly.io](https://fly.io)，
所有敏感凭证通过 `fly secrets` 注入，不硬编码进仓库，可放心公开。

## 📁 文件结构

```
frp-flyio/
├── Dockerfile           # 多阶段构建：下载 frps → 打包进最小 Alpine 镜像
├── entrypoint.sh        # 容器启动脚本：先用 envsubst 把环境变量注入到 frps.toml
├── frps.toml            # frps 配置模板（含 ${...} 占位符）
├── fly.toml             # fly.io 平台部署配置（端口、区域、健康检查）
├── frpc-example.toml    # 本地客户端配置示例（SSH/Web/RDP）
├── .dockerignore
├── .gitignore
└── README.md
```

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

### 4. 部署

```bash
fly deploy
```

等待镜像构建与推送完成（首次约 1~2 分钟）。

### 5. 验证部署

```bash
# 查看实例状态（应显示 1 running）
fly status

# 查看实时日志，正常应该看到：
# "start frps success"
# "frps tcp listen on 0.0.0.0:7000"
# "Dashboard listen on 0.0.0.0:7500"
fly logs
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
   ssh -p 6022 用户名@你的应用名.fly.dev
   ```

### ⚠️ 新增端口必须做的事

每当你在 `frpc.toml` 里新增一个使用 `remotePort` 的代理（如 RDP 的 6389），
**必须同步在 `fly.toml` 中添加对应端口的 `[[services]]` 块**（文件里已给出注释模板），
然后重新 `fly deploy`，否则 fly.io 的防火墙会阻止外部访问该端口。

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

- **免费额度**：fly.io 免费套餐包含 3 个共享 CPU 机器 + 160GB 出站流量/月，足够个人使用。
  长时间无流量的实例可能被自动暂停，本配置已设置 `auto_stop_machines = false` 保持长连。
- **版本一致**：本地 `frpc` 版本应与 Dockerfile 中的 `FRP_VERSION` 一致（默认 0.62.0），避免协议不兼容。
- **安全**：务必使用强 Token 和仪表盘密码，不要使用 123456 等弱口令。
- **密钥轮换**：如怀疑泄露，执行 `fly secrets set FRP_AUTH_TOKEN="新值"` 后客户端同步更新即可。
