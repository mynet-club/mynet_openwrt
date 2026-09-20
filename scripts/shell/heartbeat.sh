#!/bin/sh
# mynet-heartbeat — cron 包装器（主逻辑在 Lua）
#
# 调用 system.run_daemon_heartbeat()：
#   - 读取节点公钥 → HMAC-SHA256 签名 → POST /api/v2/monitor/heartbeat
#   - 认证头：X-Node-Id + X-Timestamp + X-Node-Signature（无 JWT token）
#   - 与 Go mynetd 完全对齐，永不过期
#
# cron（postinst 自动写入）：
#   */5 * * * * /usr/bin/mynet-heartbeat
#
# 依赖：lua, curl, sha256sum(busybox), base64(busybox)

MYNET_HOME="${MYNET_HOME:-/etc/mynet}"
LOG="${MYNET_HOME}/var/logs/heartbeat.log"
LOCK="/var/run/mynet_heartbeat.lock"

# 防重入
if [ -f "$LOCK" ]; then
    old_pid=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0
    fi
fi
mkdir -p "$(dirname "$LOCK")"
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

# 日志（保留最后 500 行）
mkdir -p "$(dirname "$LOG")"
_log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
    cnt=$(wc -l < "$LOG" 2>/dev/null || echo 0)
    [ "$cnt" -gt 500 ] && tail -200 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
}

# Lua 路径（OpenWrt LuCI 标准位置）
export LUA_PATH="/usr/lib/lua/?.lua;/usr/lib/lua/?/init.lua;;"

lua -e "
    local sys = require('luci.model.mynet.system')
    local ok, err = sys.run_daemon_heartbeat()
    if ok then
        io.stdout:write('ok\n')
    else
        io.stderr:write('ERROR: ' .. tostring(err) .. '\n')
        os.exit(1)
    end
" >> "$LOG" 2>&1
rc=$?

if [ $rc -eq 0 ]; then
    _log "✓ ok"
else
    _log "✗ failed (see above)"
fi

# ── GNB peer 健康检查 + 自愈重启 ────────────────────────────────
# 逻辑：proxy 运行中 → peer VIP 不可达 → 重启 GNB 进程（仅进程，不动路由/防火墙）
# 背景：GNB 初次打洞失败后指数退避重试，可能长达 1 小时不自愈；restart 即可恢复
_gnb_peer_heal() {
    local state_file="${MYNET_HOME}/var/proxy_state.json"
    local role_conf="${MYNET_HOME}/conf/proxy/proxy_role.conf"
    local heal_ts_file="/var/run/mynet_gnb_heal.ts"
    local HEAL_COOLDOWN=900   # 15 分钟内只重启一次，避免持续不通时循环抖动

    # proxy 是否在运行（state 文件存在）
    [ -f "$state_file" ] || return 0

    # proxy 运行超过 90s 后才检测（避免刚启动打洞尚未完成）
    local start_ts
    start_ts=$(grep -o '"start_ts":[0-9]*' "$state_file" | grep -o '[0-9]*$')
    [ -z "$start_ts" ] && return 0
    local now_ts; now_ts=$(date +%s)
    local age=$((now_ts - start_ts))
    if [ "$age" -lt 90 ]; then
        _log "peer-heal: proxy just started (${age}s ago), skip"
        return 0
    fi

    # 冷却检查：距上次重启不足 HEAL_COOLDOWN 秒则跳过
    if [ -f "$heal_ts_file" ]; then
        local last_heal; last_heal=$(cat "$heal_ts_file" 2>/dev/null)
        if [ -n "$last_heal" ] && [ $((now_ts - last_heal)) -lt $HEAL_COOLDOWN ]; then
            return 0   # 静默跳过，不写日志（每次心跳都跑会刷屏）
        fi
    fi

    # 读取第一个 peer VIP（PROXY_GATEWAYS=10.x.x.x，逗号分隔时取第一个）
    [ -f "$role_conf" ] || return 0
    local peer_vip
    peer_vip=$(grep '^PROXY_GATEWAYS=' "$role_conf" | head -1 \
               | sed 's/^PROXY_GATEWAYS=//' | cut -d, -f1 | tr -d '"')
    [ -z "$peer_vip" ] && return 0

    # ping 3 次，总 deadline 8s（BusyBox ping -w = total deadline）
    if ping -c 3 -w 8 "$peer_vip" >/dev/null 2>&1; then
        return 0   # peer 可达，不处理
    fi

    _log "peer-heal: $peer_vip unreachable — restarting GNB..."

    # 记录重启时间戳（冷却期开始）
    echo "$now_ts" > "$heal_ts_file"

    # 仅重启 GNB 进程（node.restart_gnb = stop_gnb + start_gnb，不动路由/防火墙）
    lua -e "
local node = require('luci.model.mynet.node')
local cfg  = require('luci.model.mynet.config')
local nid  = cfg.get_node_id()
if not nid then io.stderr:write('peer-heal: NODE_ID not configured\n'); os.exit(1) end
local ok, err = node.restart_gnb(nid)
if ok then
    io.stdout:write('peer-heal: GNB restarted OK\n')
else
    io.stderr:write('peer-heal: restart failed: ' .. tostring(err) .. '\n')
    os.exit(1)
end
" >> "$LOG" 2>&1
    local heal_rc=$?
    if [ $heal_rc -eq 0 ]; then
        _log "peer-heal: GNB restarted successfully"
    else
        _log "peer-heal: GNB restart failed (rc=$heal_rc)"
    fi
}

_gnb_peer_heal
