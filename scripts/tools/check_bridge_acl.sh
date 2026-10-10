#!/bin/sh
# check_bridge_acl.sh —— 桥的方法表与 ACL 授权必须逐一对上（防漂移）。
# 桥暴露的方法若没进 ACL → LuCI 调不到（权限不足）；ACL 授权了不存在的方法 → 冗余/笔误。
#
# 注意：本脚本要在 macOS(BSD sed/awk) 与 Linux(GNU) 上都跑得通 —— 一律不用
# GNU 扩展（`\?`、`\+`），BSD sed 会把 `\?` 当字面 `?` 从而静默零匹配。
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
UC="$ROOT/luasrc/usr/lib/rpcd/ucode/mynet.uc"
ACL="$ROOT/root/usr/share/rpcd/acl.d/luci-app-mynet.json"
[ -f "$UC" ] && [ -f "$ACL" ] || { echo "缺 mynet.uc 或 ACL"; exit 1; }

# 从 .uc 的 `const methods = { ... };` 段提取顶层方法名（裸键 status: 或单引号键 'node-status':）
# awk 切片用 `/^const methods =/` 起、`/^\};/` 止 —— 不写 `\{`，避开 BSD/GNU 花括号歧义。
uc_methods=$(awk '/^const methods =/{f=1;next} /^\};/{f=0} f' "$UC" \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*:.*$//' -e "s/['\"]//g" \
  | grep -v '^$' | sort -u)

# ACL 里 mynet 的方法（read + write 两段 ubus.mynet 数组，逐段抓取）
acl_methods=$(tr -d ' \n\t' < "$ACL" \
  | grep -o '"mynet":\[[^]]*\]' \
  | sed -e 's/.*\[//' -e 's/\]//' -e "s/['\"]//g" \
  | tr ',' '\n' | grep -v '^$' | sort -u)

uc_n=$(printf '%s\n' "$uc_methods" | grep -c .)
acl_n=$(printf '%s\n' "$acl_methods" | grep -c .)

# 落到临时文件再用 `< file` 逐行读 —— 不用管道，避免 while 落进子壳导致 miss 丢失。
ucf=$(mktemp); aclf=$(mktemp); trap 'rm -f "$ucf" "$aclf"' EXIT
printf '%s\n' "$uc_methods"  > "$ucf"
printf '%s\n' "$acl_methods" > "$aclf"

miss=0
while IFS= read -r m; do
  [ -z "$m" ] && continue
  grep -qx "$m" "$aclf" || { echo "✗ 桥方法未授权: $m"; miss=1; }
done < "$ucf"
while IFS= read -r m; do
  [ -z "$m" ] && continue
  grep -qx "$m" "$ucf" || { echo "✗ ACL 授权了不存在的方法: $m"; miss=1; }
done < "$aclf"

[ "$uc_n" = "$acl_n" ] || { echo "✗ 数量不一致: 桥 $uc_n / ACL $acl_n"; exit 1; }
[ "$miss" = 0 ] || exit 1
echo "✓ 桥方法($uc_n) 与 ACL 授权($acl_n) 一致"
