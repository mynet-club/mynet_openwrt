#!/bin/sh
# check_bridge_acl.sh —— 桥的三处方法表必须逐一对上（防漂移）。
#
# 三方：
#   1. rpcd 桥      luasrc/usr/lib/rpcd/ucode/mynet.uc   （methods = { ... }）
#   2. ubus ACL     root/usr/share/rpcd/acl.d/luci-app-mynet.json（read+write ubus.mynet）
#   3. LuCI 客户端  luasrc/model/mynet/bridge.lua        （M.METHODS = { ... }）
# 任一暴露的方法没进另两处 → 页面调不到（ACL 拒）或调不存在的（笔误）。
#
# 注意：本脚本要在 macOS(BSD sed/awk) 与 Linux(GNU) 上都跑得通 —— 一律不用
# GNU 扩展（`\?`、`\+`），BSD sed 会把 `\?` 当字面 `?` 从而静默零匹配。
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
UC="$ROOT/luasrc/usr/lib/rpcd/ucode/mynet.uc"
ACL="$ROOT/root/usr/share/rpcd/acl.d/luci-app-mynet.json"
BRIDGE="$ROOT/luasrc/model/mynet/bridge.lua"
for f in "$UC" "$ACL" "$BRIDGE"; do
  [ -f "$f" ] || { echo "缺文件: $f"; exit 1; }
done

# 1. 桥：`const methods = { ... };` 段顶层方法名（裸键 status: 或引号键 'node-status':）
uc_methods=$(awk '/^const methods =/{f=1;next} /^\};/{f=0} f' "$UC" \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*:.*$//' -e "s/['\"]//g" \
  | grep -v '^$' | sort -u)

# 2. ACL：read + write 两段 ubus.mynet 数组
acl_methods=$(tr -d ' \n\t' < "$ACL" \
  | grep -o '"mynet":\[[^]]*\]' \
  | sed -e 's/.*\[//' -e 's/\]//' -e "s/['\"]//g" \
  | tr ',' '\n' | grep -v '^$' | sort -u)

# 3. LuCI 客户端：`M.METHODS = { ... }` 段里的引号常量
bridge_methods=$(awk '/^M\.METHODS = \{/{f=1;next} f && /^\}/{f=0} f' "$BRIDGE" \
  | grep -o '"[^"]*"' | tr -d '"' | grep -v '^$' | sort -u)

uc_n=$(printf '%s\n' "$uc_methods" | grep -c .)
acl_n=$(printf '%s\n' "$acl_methods" | grep -c .)
bridge_n=$(printf '%s\n' "$bridge_methods" | grep -c .)

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
printf '%s\n' "$uc_methods"     > "$tmp/uc"
printf '%s\n' "$acl_methods"    > "$tmp/acl"
printf '%s\n' "$bridge_methods" > "$tmp/bridge"

fail=0
# 两两比对：以「先出现者」为基准，另一侧缺项即报错（miss 与 extra 都会红）。
# 参数：<基准文件> <基准名> <对象文件> <对象名>
diff_lists() {
  base=$1; bname=$2; other=$3; oname=$4
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    grep -qx "$m" "$other" || { echo "✗ $bname 有、$oname 无: $m"; fail=1; }
  done < "$base"
}
diff_lists "$tmp/uc" "桥(.uc)"     "$tmp/acl"    "ACL"
diff_lists "$tmp/uc" "桥(.uc)"     "$tmp/bridge" "LuCI(bridge.lua)"
diff_lists "$tmp/acl" "ACL"        "$tmp/bridge" "LuCI(bridge.lua)"

[ "$uc_n" = "$acl_n" ] || { echo "✗ 数量不一致: 桥 $uc_n / ACL $acl_n"; exit 1; }
[ "$uc_n" = "$bridge_n" ] || { echo "✗ 数量不一致: 桥 $uc_n / LuCI $bridge_n"; exit 1; }
[ "$fail" = 0 ] || exit 1
echo "✓ 三方一致：桥 $uc_n = ACL $acl_n = LuCI $bridge_n"
