#!/usr/bin/env bash
# install-openwrt.sh — **调试脚手架**（QEMU/开发迭代用）
#
# ⚠️ 产品安装面是 `mynet install`（mynet_agent，OpenWrt 走 procd 分支，
#    写 /etc/init.d/{mynetd,mynet}）。本脚本只服务开发机 → 调试 VM 的快速同步，
#    不要在生产设备上代替 mynet install。
#
# 用法:
#   bash debug/install-openwrt.sh              # 构建 + 安装 + 冒烟（默认）
#   bash debug/install-openwrt.sh build        # 仅交叉编译 mynetd/mynet
#   bash debug/install-openwrt.sh install      # 仅安装二进制 + init
#   bash debug/install-openwrt.sh luci         # 仅同步 LuCI 壳
#   bash debug/install-openwrt.sh smoke        # 仅冒烟（detector→stop→start→routes）
#
# 环境变量:
#   ROUTER      SSH 目标（默认 openwrt-qemu）
#   GOARCH      默认 arm64
#   EMBED       mynetd 是否带 WebUI（默认 0，OpenWrt 目标态）
#
# 前置:
#   1. VM/设备 SSH 免密可达（调试 VM：mynet_lua/debug/vm start）
#   2. 本机有 go 1.22+
#
# 装完之后的期望状态:
#   /usr/sbin/mynetd  + /etc/init.d/mynetd（MYNET_EXECUTOR=lua）
#   /usr/sbin/mynet   （L6：apply / detector）
#   /usr/lib/lua/luci/...  + /usr/share/luci/menu.d/luci-app-mynet.json
#   gnb 可 service start/stop，tun + 路由正确
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWRT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_DIR="${AGENT_DIR:-$SCRIPT_DIR/../../mynet_agent}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/out}"
ROUTER="${ROUTER:-openwrt-qemu}"
GOOS="${GOOS:-linux}"
GOARCH="${GOARCH:-arm64}"
GOMIPS="${GOMIPS:-softfloat}"
EMBED="${EMBED:-0}"
SSH_OPTS=(-o ConnectTimeout=5 -o BatchMode=yes)

log()  { printf '[install-openwrt] %s\n' "$*"; }
die()  { printf '[install-openwrt] ✗ %s\n' "$*" >&2; exit 1; }

resolve_version() {
    if [ -n "${VERSION:-}" ]; then printf '%s\n' "$VERSION"; return; fi
    local desc
    desc="$(git -C "$AGENT_DIR" describe --tags --always --dirty 2>/dev/null || true)"
    if [ -z "$desc" ]; then printf 'v0.0.0-dev\n'
    elif printf '%s' "$desc" | grep -q '^v'; then printf '%s\n' "$desc"
    else printf 'v0.0.0-%s\n' "$desc"; fi
}

do_build() {
    command -v go >/dev/null || die "缺少 go"
    [ -d "$AGENT_DIR" ] || die "找不到 mynet_agent: $AGENT_DIR"
    local ver ldflags tags_arg=()
    ver="$(resolve_version)"
    ldflags="-X github.com/mynet-club/mynet_agent/shared/utils.AppVersion=$ver"
    ldflags="$ldflags -X github.com/mynet-club/mynet_agent/mynet.Version=$ver"
    [ "$EMBED" = "1" ] && tags_arg=(-tags embed)
    local gomips_env=()
    case "$GOARCH" in mips*|mips64*) gomips_env=(GOMIPS="$GOMIPS") ;; esac

    mkdir -p "$OUT_DIR"
    log "构建 mynetd+mynet GOOS=$GOOS GOARCH=$GOARCH EMBED=$EMBED ver=$ver"
    ( cd "$AGENT_DIR" && env CGO_ENABLED=0 GOOS="$GOOS" GOARCH="$GOARCH" "${gomips_env[@]}" \
        go build -ldflags "$ldflags" "${tags_arg[@]}" -o "$OUT_DIR/mynetd" ./cmd/mynetd )
    ( cd "$AGENT_DIR" && env CGO_ENABLED=0 GOOS="$GOOS" GOARCH="$GOARCH" "${gomips_env[@]}" \
        go build -ldflags "$ldflags" -o "$OUT_DIR/mynet" ./cmd/mynet )
    log "产物: $(ls -1 "$OUT_DIR/mynetd" "$OUT_DIR/mynet")"
}

do_install() {
    ssh "${SSH_OPTS[@]}" "$ROUTER" true 2>/dev/null \
        || die "SSH 不可达: $ROUTER（先 vm start）"
    [ -f "$OUT_DIR/mynetd" ] && [ -f "$OUT_DIR/mynet" ] \
        || die "缺产物，先跑: bash debug/install-openwrt.sh build"

    log "安装二进制 + procd init → $ROUTER"
    scp "${SSH_OPTS[@]}" "$OUT_DIR/mynetd" "$ROUTER:/tmp/mynetd.io"
    scp "${SSH_OPTS[@]}" "$OUT_DIR/mynet"  "$ROUTER:/tmp/mynet.io"
    # procd 单元以 mynet_agent/mynet/units/ 为 SSOT（mynet install 用同一套 embed）
    scp "${SSH_OPTS[@]}" "$AGENT_DIR/mynet/units/openwrt_mynetd.init" "$ROUTER:/etc/init.d/mynetd"
    scp "${SSH_OPTS[@]}" "$AGENT_DIR/mynet/units/openwrt_mynet.init"  "$ROUTER:/etc/init.d/mynet"
    ssh "${SSH_OPTS[@]}" "$ROUTER" "
        mv /tmp/mynetd.io /usr/sbin/mynetd && chmod 755 /usr/sbin/mynetd
        mv /tmp/mynet.io  /usr/sbin/mynet  && chmod 755 /usr/sbin/mynet
        chmod 755 /etc/init.d/mynetd /etc/init.d/mynet
        /etc/init.d/mynetd enable 2>/dev/null || true
        /etc/init.d/mynetd restart 2>/dev/null || /etc/init.d/mynetd start
        /etc/init.d/mynet enable 2>/dev/null || true
    "
    log "mynetd/mynet + procd init 已安装"
}

do_luci() {
    ssh "${SSH_OPTS[@]}" "$ROUTER" true 2>/dev/null || die "SSH 不可达"
    local R="$ROUTER" SRC="$OPENWRT_DIR"
    log "同步 LuCI 壳"
    ssh "${SSH_OPTS[@]}" "$R" 'mkdir -p \
        /usr/lib/lua/luci/controller \
        /usr/lib/lua/luci/model/mynet \
        /usr/lib/lua/luci/view/mynet \
        /www/luci-static/resources/mynet/css \
        /www/luci-static/resources/mynet/js \
        /usr/share/luci/menu.d \
        /usr/share/rpcd/acl.d'
    scp -q "${SSH_OPTS[@]}" "$SRC/luasrc/controller/mynet.lua" "$R:/usr/lib/lua/luci/controller/"
    scp -q "${SSH_OPTS[@]}" "$SRC/luasrc/model/mynet/"*.lua "$R:/usr/lib/lua/luci/model/mynet/"
    scp -q "${SSH_OPTS[@]}" "$SRC/luasrc/view/mynet/"*.htm "$R:/usr/lib/lua/luci/view/mynet/"
    scp -q "${SSH_OPTS[@]}" "$SRC/htdocs/luci-static/resources/mynet/css/"* "$R:/www/luci-static/resources/mynet/css/"
    scp -q "${SSH_OPTS[@]}" "$SRC/htdocs/luci-static/resources/mynet/js/"* "$R:/www/luci-static/resources/mynet/js/"
    scp -q "${SSH_OPTS[@]}" "$SRC/root/usr/share/luci/menu.d/luci-app-mynet.json" "$R:/usr/share/luci/menu.d/"
    scp -q "${SSH_OPTS[@]}" "$SRC/root/usr/share/rpcd/acl.d/luci-app-mynet.json" "$R:/usr/share/rpcd/acl.d/" 2>/dev/null || true
    ssh "${SSH_OPTS[@]}" "$R" 'rm -rf /tmp/luci-*'
    log "LuCI 壳已同步"
}

do_smoke() {
    ssh "${SSH_OPTS[@]}" "$ROUTER" true 2>/dev/null || die "SSH 不可达"
    log "冒烟：detector → service stop/start → 路由"
    ssh "${SSH_OPTS[@]}" "$ROUTER" '
        set -e
        echo -n "mynetd env: "; tr "\0" "\n" < /proc/$(pgrep mynetd)/environ | grep MYNET_EXECUTOR || echo MISSING
        echo -n "localapi: "; curl -s -m 3 http://127.0.0.1:8096/api/v1/status | head -c 120; echo

        echo -n "detector: "
        curl -s -m 40 -X POST http://127.0.0.1:8096/api/v1/command \
          -H "Content-Type: application/json" \
          -d "{\"argv\":[\"detector\",\"--json\"]}" | grep -q "\"success\":true" && echo OK || echo FAIL
        test -f /etc/mynet/var/system.json && echo "  system.json OK" || echo "  system.json MISSING"

        echo -n "service stop: "
        curl -s -m 25 -X POST http://127.0.0.1:8096/api/v1/command \
          -H "Content-Type: application/json" \
          -d "{\"argv\":[\"service\",\"stop\"]}" | grep -q "\"success\":true" && echo OK || echo FAIL
        sleep 1
        pgrep gnb >/dev/null && echo "  FAIL gnb still running" || echo "  gnb stopped OK"

        echo -n "service start: "
        curl -s -m 40 -X POST http://127.0.0.1:8096/api/v1/command \
          -H "Content-Type: application/json" \
          -d "{\"argv\":[\"service\",\"start\"]}" | grep -q "\"success\":true" && echo OK || echo FAIL
        sleep 2
        pgrep gnb >/dev/null && echo "  gnb running OK" || echo "  FAIL gnb not running"
        echo -n "  pidfile="; cat /etc/mynet/driver/gnb/conf/*/gnb.pid 2>/dev/null; echo
        echo -n "  tun="; ip link show gnb_tun 2>/dev/null | head -1
        echo -n "  routes="; ip route show dev gnb_tun 2>/dev/null | head -2
    '
    log "✓ 冒烟通过"
}

case "${1:-all}" in
    build)   do_build ;;
    install) do_install ;;
    luci)    do_luci ;;
    smoke)   do_smoke ;;
    all)     do_build; do_install; do_luci; do_smoke ;;
    *) echo "用法: $0 [build|install|luci|smoke|all]"; exit 1 ;;
esac
