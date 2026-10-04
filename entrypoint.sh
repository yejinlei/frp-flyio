#!/bin/sh
set -e

# 使用 envsubst 把模板里的 ${VAR} 替换为真实环境变量值，
# 生成运行时用的 frps.toml / frps-udp.toml，再启动两个 frps 实例：
#   :7000 -> 主实例（tcp / http / https），代理绑 0.0.0.0
#   :7001 -> UDP 实例，代理绑 fly-global-services（fly.io UDP 的唯一正确姿势）
VARS='${FRP_AUTH_TOKEN} ${FRP_DASHBOARD_USER} ${FRP_DASHBOARD_PWD}'

echo "[entrypoint] rendering /etc/frp/*.tmpl ..."
envsubst "$VARS" < /etc/frp/frps.toml.tmpl     > /tmp/frps.toml
envsubst "$VARS" < /etc/frp/frps-udp.toml.tmpl > /tmp/frps-udp.toml

shutdown() {
  echo "[entrypoint] received signal, stopping frps..."
  [ -n "$PID_MAIN" ] && kill "$PID_MAIN" 2>/dev/null || true
  [ -n "$PID_UDP" ]  && kill "$PID_UDP"  2>/dev/null || true
  wait
}
trap shutdown TERM INT

echo "[entrypoint] starting frps main (tcp/http/https) on :7000 ..."
frps -c /tmp/frps.toml &
PID_MAIN=$!

echo "[entrypoint] starting frps udp on :7001 ..."
frps -c /tmp/frps-udp.toml &
PID_UDP=$!

wait
