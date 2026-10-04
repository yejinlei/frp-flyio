#!/bin/sh
set -e

# 使用 envsubst 把模板里的 ${VAR} 替换为真实环境变量值，
# 生成运行时用的 frps.toml，再启动 frps
echo "[entrypoint] rendering /etc/frp/frps.toml from template..."
envsubst '${FRP_AUTH_TOKEN} ${FRP_DASHBOARD_USER} ${FRP_DASHBOARD_PWD}' \
  < /etc/frp/frps.toml.tmpl \
  > /tmp/frps.toml

echo "[entrypoint] starting frps..."
exec frps -c /tmp/frps.toml
