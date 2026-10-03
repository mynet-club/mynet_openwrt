#!/usr/bin/env bash
# build-install.sh — mynet_agent 交叉编译 → OpenWrt VM 安装（可复现）
#
# 为什么单独有这份：mynetd 是 **CGO_ENABLED=0 静态 Go**，与 glibc/musl 无关，
# macOS 上一条 go build 就能出目标架构产物；缺的是「编出来 → 装进 VM → 冒烟」
# 这条流水线的固化。C 侧的 gnb 走 Makefile.openwrt*，不在此脚本范围。
#
# 用法:
#   bash debug/build-install.sh              # 构建 + 安装 + 冒烟（默认）
#   bash debug/build-install.sh build        # 仅交叉编译
#   bash debug/build-install.sh install      # 仅安装（用上一次 build 产物）
#   bash debug/build-install.sh smoke        # 仅冒烟测试
#   bash debug/build-install.sh all          # 同默认
#
# 环境变量（均有默认值）:
#   ROUTER      SSH 目标（默认 openwrt-qemu，见 ~/.ssh/config）
#   GOOS        默认 linux
#   GOARCH      默认 arm64（OpenWrt 24.10 armsr-armv8 / 本调试 VM）
#   GOMIPS      默认 softfloat（仅 GOARCH=mips* 时有意义）
#   EMBED       1=mynetd 带 WebUI embed；0=瘦构建（默认 0，OpenWrt 目标态）
#   AGENT_DIR   mynet_agent 路径（默认 <本文件>/../../mynet_agent）
#   OUT_DIR     产物目录（默认 <本文件>/out）
#   VERSION     覆盖版本号（默认 git describe，与 mynet_agent/Makefile 同规则）
#   WITH_MYNET  1=同时构建并安装 mynet 执行器（默认 1；L6 路由唯一写入者 mynet apply）
#               OpenWrt 命令执行走 lua -e（mynetd.init 设 MYNET_EXECUTOR=lua），
#               但 Lua apply_routes 仍会 shell 调 mynet apply —— 所以两个都要装。
#
# 前置:
#   1. 调试 VM 已启动（mynet_lua/debug/vm start，或 bash debug/start.sh）
#   2. `ssh openwrt-qemu` 免密可达
#   3. 本机有 go（1.22+）
#
# 设计取舍:
#   - 走 ssh/scp 而不是 ipk：开发迭代要快；正式 ipk 见 mynet_openwrt/Makefile
#     的 Package/mynet-agent（缺 files/mynetd 会拒绝出包，V2-9）。
#   - 默认瘦构建（无 embed）：D-11 定的是「OpenWrt = mynetd 无 embed」；
#     界面走 LuCI。EMBED=1 留给需要调 localapi WebUI 的场合。
#   - 不按名字杀进程（安全红线）：重启一律走 /etc/init.d/mynetd。
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
WITH_MYNET="${WITH_MYNET:-1}"
SSH_OPTS=(-o ConnectTimeout=5 -o BatchMode=yes)

log()  { printf '[build-install] %s\n' "$*"; }
die()  { printf '[build-install] ✗ %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"; }

# ── 版本（与 mynet_agent/Makefile 同规则：tag 优先，否则 v0.0.0-<sha>，脏则 -dirty）──
resolve_version() {
    if [ -n "${VERSION:-}" ]; then
        printf '%s\n' "$VERSION"
        return
    fi
    local desc
    desc="$(git -C "$AGENT_DIR" describe --tags --always --dirty 2>/dev/null || true)"
    if [ -z "$desc" ]; then
        printf 'v0.0.0-dev\n'
    elif printf '%s' "$desc" | grep -q '^v'; then
        printf '%s\n' "$desc"
    else
        printf 'v0.0.0-%s\n' "$desc"
    fi
}

# ── 预检 ──────────────────────────────────────────────────────
preflight_build() {
    need go
    [ -d "$AGENT_DIR" ] || die "找不到 mynet_agent: $AGENT_DIR"
    [ -f "$AGENT_DIR/go.mod" ] || die "$AGENT_DIR 不是 Go 模块（缺 go.mod）"
    [ -f "$AGENT_DIR/cmd/mynetd/main.go" ] || die "缺 cmd/mynetd/main.go"
}

preflight_vm() {
    need ssh
    need scp
    ssh "${SSH_OPTS[@]}" "$ROUTER" true 2>/dev/null \
        || die "SSH 不可达: $ROUTER —— 先启动 VM（mynet_lua/debug/vm start）并确认 ~/.ssh/config"
}

# ── 构建 ──────────────────────────────────────────────────────
do_build() {
    preflight_build
    local ver ldflags tags_arg
    ver="$(resolve_version)"
    # -s -w 是链接器标志，必须经 -ldflags（直接给 go build 会报 flag not defined）
    ldflags="-s -w"
    ldflags="$ldflags -X github.com/mynet-club/mynet_agent/shared/utils.AppVersion=$ver"
    ldflags="$ldflags -X github.com/mynet-club/mynet_agent/mynet.Version=$ver"
    tags_arg=()
    if [ "$EMBED" = "1" ]; then
        tags_arg=(-tags embed)
    fi

    mkdir -p "$OUT_DIR"
    log "构建 mynetd  GOOS=$GOOS GOARCH=$GOARCH EMBED=$EMBED VERSION=$ver"
    if [ "$WITH_MYNET" = "1" ]; then
        log "构建 mynet   GOOS=$GOOS GOARCH=$GOARCH VERSION=$ver"
    fi

    # GOMIPS 只对 mips/mipsle 有意义；其它架构带上也无害，但不传更干净
    local gomips_env=()
    case "$GOARCH" in
        mips|mipsle|mips64|mips64le) gomips_env=(GOMIPS="$GOMIPS") ;;
    esac

    ( cd "$AGENT_DIR" \
        && env CGO_ENABLED=0 GOOS="$GOOS" GOARCH="$GOARCH" "${gomips_env[@]}" \
            go build -ldflags "$ldflags" "${tags_arg[@]}" \
            -o "$OUT_DIR/mynetd" ./cmd/mynetd )
    if [ "$WITH_MYNET" = "1" ]; then
        ( cd "$AGENT_DIR" \
            && env CGO_ENABLED=0 GOOS="$GOOS" GOARCH="$GOARCH" "${gomips_env[@]}" \
                go build -ldflags "$ldflags" \
                -o "$OUT_DIR/mynet" ./cmd/mynet )
    fi

    log "产物:"
    ls -lh "$OUT_DIR/mynetd"
    if [ "$WITH_MYNET" = "1" ]; then
        ls -lh "$OUT_DIR/mynet"
    fi

    # 静态性自检：Go 纯静态产物不应残留动态解释器路径
    if strings "$OUT_DIR/mynetd" | grep -qE '^/lib/ld-musl|^/lib/ld-linux|^/lib64/ld-linux'; then
        die "mynetd 疑似动态链接 —— 确认 CGO_ENABLED=0 未被覆盖"
    fi
    log "静态性自检通过（无 musl/glibc 解释器路径）"
}

# ── 安装 ──────────────────────────────────────────────────────
do_install() {
    preflight_vm
    [ -f "$OUT_DIR/mynetd" ] || die "缺 $OUT_DIR/mynetd —— 先跑: bash debug/build-install.sh build"

    local init_src="$OPENWRT_DIR/scripts/runtime/mynetd.init"
    [ -f "$init_src" ] || die "缺 $init_src"

    log "安装 mynetd → $ROUTER:/usr/sbin/mynetd"
    scp "${SSH_OPTS[@]}" "$OUT_DIR/mynetd" "$ROUTER:/tmp/mynetd.build-install"

    local cmds=(
        'mv /tmp/mynetd.build-install /usr/sbin/mynetd'
        'chmod 755 /usr/sbin/mynetd'
    )
    if [ "$WITH_MYNET" = "1" ] && [ -f "$OUT_DIR/mynet" ]; then
        log "安装 mynet  → $ROUTER:/usr/sbin/mynet"
        scp "${SSH_OPTS[@]}" "$OUT_DIR/mynet" "$ROUTER:/tmp/mynet.build-install"
        cmds+=('mv /tmp/mynet.build-install /usr/sbin/mynet' 'chmod 755 /usr/sbin/mynet')
    fi

    log "安装 mynetd.init → $ROUTER:/etc/init.d/mynetd"
    scp "${SSH_OPTS[@]}" "$init_src" "$ROUTER:/tmp/mynetd.init.build-install"
    cmds+=(
        'mv /tmp/mynetd.init.build-install /etc/init.d/mynetd'
        'chmod 755 /etc/init.d/mynetd'
    )

    # 重启走 init 系统，不按名字杀进程（安全红线）
    cmds+=(
        '/etc/init.d/mynetd enable 2>/dev/null || true'
        '/etc/init.d/mynetd restart 2>/dev/null || /etc/init.d/mynetd start'
    )

    ssh "${SSH_OPTS[@]}" "$ROUTER" "$(printf '%s; ' "${cmds[@]}")"
    log "安装完成"
}

# ── 冒烟 ──────────────────────────────────────────────────────
do_smoke() {
    preflight_vm
    log "冒烟 1/3  -version"
    ssh "${SSH_OPTS[@]}" "$ROUTER" '/usr/sbin/mynetd -version' \
        || die "-version 失败"

    log "冒烟 2/3  -once（独立端口，不占 8096）"
    ssh "${SSH_OPTS[@]}" "$ROUTER" \
        '/usr/sbin/mynetd -once -listen 127.0.0.1:18096; echo "exit=$?"' \
        || die "-once 失败"

    log "冒烟 3/3  init 状态"
    ssh "${SSH_OPTS[@]}" "$ROUTER" \
        '/etc/init.d/mynetd status; ls -la /usr/sbin/mynetd /etc/init.d/mynetd' \
        || die "init 状态检查失败"

    log "✓ 冒烟通过"
}

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

main() {
    local cmd="${1:-all}"
    case "$cmd" in
        build)   do_build ;;
        install) do_install ;;
        smoke)   do_smoke ;;
        all)     do_build && do_install && do_smoke ;;
        -h|--help|help) usage ;;
        *) die "未知子命令: ${cmd}（build|install|smoke|all）" ;;
    esac
}

main "$@"
