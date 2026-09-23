#!/bin/sh
# E-1 前置验证：gnb_es 子进程在 gnb 崩溃后是否会留孤儿（PPID=1）。
#
# 背景（隐性知识）：Lua 靠 PPID 匹配 + 按二进制路径兜底清理 gnb_es。
# procd respawn 接管 gnb 前必须验证——respawn 只拉 gnb，不清理 gnb_es。
#
# 用法（实机 root）：
#   sh verify_gnb_es_orphan.sh           # 现状报告
#   sh verify_gnb_es_orphan.sh --crash   # 杀 gnb 模拟崩溃，观察 gnb_es（会短暂断流）
#   sh verify_gnb_es_orphan.sh --clean   # 清理孤儿 gnb_es（仅本安装路径）
#
# 退出码：0=无孤儿/清理完成；1=发现孤儿且未 --clean；2=环境不满足
set -e

GNB_BIN_DIR="${GNB_BIN_DIR:-/usr/bin}"
MODE="${1:-report}"

log() { echo "[verify-gnb-es] $*"; }

count_gnb_es() {
    pidof gnb_es 2>/dev/null | wc -w | tr -d ' '
}

list_gnb_es() {
    pidof gnb_es 2>/dev/null | tr ' ' '\n' | while read -r pid; do
        [ -n "$pid" ] || continue
        ppid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || echo '?')
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null || echo '?')
        echo "pid=$pid ppid=$ppid exe=$exe"
    done
}

list_orphans() {
    # PPID=1 且二进制在本安装路径 → 孤儿
    pidof gnb_es 2>/dev/null | tr ' ' '\n' | while read -r pid; do
        [ -n "$pid" ] || continue
        ppid=$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || echo '')
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null || echo '')
        if [ "$ppid" = "1" ]; then
            case "$exe" in
                "$GNB_BIN_DIR"/*) echo "$pid" ;;
            esac
        fi
    done
}

case "$MODE" in
report)
    log "gnb_es count=$(count_gnb_es)"
    list_gnb_es
    orphans=$(list_orphans | tr '\n' ' ')
    if [ -n "$orphans" ]; then
        log "ORPHANS: $orphans"
        exit 1
    fi
    log "no orphans"
    ;;
--crash)
    # 模拟崩溃：杀 **指定实例** 的 gnb，观察 gnb_es 是否被回收
    # 多实例安全：优先 GNB_PID / GNB_CONF cmdline 匹配，绝不 pidof 取第一个
    gpid="${GNB_PID:-}"
    if [ -z "$gpid" ] && [ -n "$GNB_CONF" ]; then
        gpid=$(pgrep -f "gnb -c $GNB_CONF" 2>/dev/null | head -1)
    fi
    if [ -z "$gpid" ]; then
        gpid=$(pgrep -f "gnb -c /tmp/t1-gnb" 2>/dev/null | head -1)
    fi
    if [ -z "$gpid" ]; then
        log "no target gnb (set GNB_PID or GNB_CONF); refuse to kill by name"
        exit 2
    fi
    before=$(count_gnb_es)
    log "gnb pid=$gpid, gnb_es=$before; SIGKILL gnb..."
    kill -9 "$gpid" 2>/dev/null || true
    i=0
    while [ $i -lt 6 ]; do
        sleep 1
        i=$((i + 1))
        now=$(count_gnb_es)
        log "t+${i}s gnb_es=$now"
    done
    orphans=$(list_orphans | tr '\n' ' ')
    if [ -n "$orphans" ]; then
        log "FAIL: leftover orphans: $orphans"
        log "procd respawn 前必须先解决（跑 --clean 或修 Lua 清理）"
        exit 1
    fi
    log "PASS: no gnb_es orphans after gnb crash"
    ;;
--clean)
    for pid in $(list_orphans); do
        log "killing orphan gnb_es pid=$pid"
        kill "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
    done
    log "clean done; remaining=$(count_gnb_es)"
    ;;
*)
    echo "usage: $0 [report|--crash|--clean]"
    exit 2
    ;;
esac
