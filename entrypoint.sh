#!/bin/sh
set -e

# 使用 envsubst 把模板里的 ${VAR} 替换为真实环境变量值，
# 生成运行时用的 frps.toml / frps-udp.toml，再启动两个 frps 实例：
#   :7000 -> 主实例（tcp / http / https / tcpmux / stcp / sudp / xtcp），代理绑 0.0.0.0
#   :7001 -> UDP 实例，代理绑 fly-global-services（fly.io UDP 的唯一正确姿势）
#
# 两个实例各由一个 supervise() 循环守护：某个实例崩溃后 2s 内自行拉起，
# 不需要等 fly 的健康检查失败后整机重启（整机重启会打断所有已建立的隧道）。
VARS='${FRP_AUTH_TOKEN} ${FRP_DASHBOARD_USER} ${FRP_DASHBOARD_PWD}'

echo "[entrypoint] rendering /etc/frp/*.tmpl ..."
envsubst "$VARS" < /etc/frp/frps.toml.tmpl     > /tmp/frps.toml
envsubst "$VARS" < /etc/frp/frps-udp.toml.tmpl > /tmp/frps-udp.toml

# ---------------------------------------------------------------------------
# 单实例守护
#   $1 = 日志标签（main / udp）   $2 = 配置文件路径
#
# 规则：
#   1. frps 退出就重启，不再出现“容器还活着但某个实例没了”的半死状态；
#   2. 退避递增 2 → 4 → 8 → 16 → 30s。配置错误导致 frps 秒退时，
#      不会无限疯狂重启把日志刷爆；
#   3. 只要某次运行撑过 30s，就认为它健康，退避重新归零，
#      后续真出故障依然能秒级恢复。
# ---------------------------------------------------------------------------
supervise() {
  tag=$1
  cfg=$2
  delay=2

  while true; do
    started=$(date +%s)
    echo "[entrypoint] >>> [$tag] starting: frps -c $cfg"

    frps -c "$cfg" &
    child=$!
    trap 'echo "[entrypoint] [$tag] stopping (pid $child)"; kill "$child" 2>/dev/null; exit 0' TERM INT

    rc=0
    wait "$child" || rc=$?

    finished=$(date +%s)
    lived=$((finished - started))
    echo "[entrypoint] !!! [$tag] exited rc=$rc after ${lived}s, restart in ${delay}s"

    if [ "$lived" -ge 30 ]; then
      delay=2                              # 上次不是秒退，重置退避
    else
      delay=$((delay * 2))
      [ "$delay" -gt 30 ] && delay=30
    fi

    sleep "$delay"
  done
}

shutdown() {
  echo "[entrypoint] received stop signal, stopping supervisors..."
  [ -n "$PID_MAIN" ] && kill "$PID_MAIN" 2>/dev/null || true
  [ -n "$PID_UDP" ]  && kill "$PID_UDP"  2>/dev/null || true
  wait
}
trap shutdown TERM INT

supervise main /tmp/frps.toml &
PID_MAIN=$!

supervise udp /tmp/frps-udp.toml &
PID_UDP=$!

wait
