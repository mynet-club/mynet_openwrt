include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mynet
PKG_VERSION:=2.1.8
# opkg 判「是不是升级」用的是 version-release。PKG_RELEASE 固定成 1 时，同一
# 产品版本下的任何重建在 opkg 眼里都是「已是最新」—— 升级必须 --force-reinstall，
# 否则静默不动。CI 传入本次构建的**单调**序号（git 提交计数：同提交可复现、
# 跨提交递增）覆盖它；没传（本地手编）时退回 1。
PKG_RELEASE:=$(if $(MYNET_PKG_RELEASE),$(MYNET_PKG_RELEASE),1)

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-mynet
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI support for MyNet VPN
  DEPENDS:=+luci-base +curl +luci-lib-jsonc +bash +kmod-tun +ucode-mod-lua +luci-lib-base +luci-lib-nixio +luci-lib-ip +liblucihttp-lua +libubus-lua
  PKGARCH:=all
endef

define Package/luci-app-mynet/description
  MyNet VPN management interface for OpenWrt.
  Provides zone/node management, config sync, and VPN control
  through the LuCI web interface.
endef

# 运维配置必须声明为 conffiles：否则 opkg 把它当普通文件，升级时**无声覆盖**
# 设备上的改动（此前正是如此）。声明后 opkg 保留设备侧内容并提示。
define Package/luci-app-mynet/conffiles
/etc/mynet/conf/config.json
endef

define Build/Compile
endef

define Package/luci-app-mynet/install
	# --- LuCI controller ---
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/mynet.lua $(1)/usr/lib/lua/luci/controller/

	# --- LuCI model ---
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/mynet
	$(INSTALL_DATA) ./luasrc/model/mynet/*.lua $(1)/usr/lib/lua/luci/model/mynet/

	# --- LuCI view ---
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/view/mynet
	$(INSTALL_DATA) ./luasrc/view/mynet/*.htm $(1)/usr/lib/lua/luci/view/mynet/

	# --- Static assets ---
	$(INSTALL_DIR) $(1)/www/luci-static/resources/mynet/css
	$(INSTALL_DATA) ./htdocs/luci-static/resources/mynet/css/mynet.css \
		$(1)/www/luci-static/resources/mynet/css/
	$(INSTALL_DIR) $(1)/www/luci-static/resources/mynet/js
	$(INSTALL_DATA) ./htdocs/luci-static/resources/mynet/js/mynet.js \
		$(1)/www/luci-static/resources/mynet/js/

	# --- Default config ---
	$(INSTALL_DIR) $(1)/etc/mynet/conf
	$(INSTALL_CONF) ./root/etc/mynet/conf/config.json $(1)/etc/mynet/conf/

	# init 不再随包（由 mynet install 从 agent 内嵌模板写出，见 O1）

	# --- rpcd ucode 桥（O2）→ /usr/share/rpcd/ucode/（rpcd 实际加载目录，本机实测） ---
	$(INSTALL_DIR) $(1)/usr/share/rpcd/ucode
	$(INSTALL_DATA) ./luasrc/usr/lib/rpcd/ucode/mynet.uc $(1)/usr/share/rpcd/ucode/mynet.uc

	# --- Runtime scripts: proxy ---
	$(INSTALL_DIR) $(1)/etc/mynet/scripts/proxy/hooks
	$(INSTALL_BIN) ./scripts/proxy/proxy.sh $(1)/etc/mynet/scripts/proxy/
	$(INSTALL_BIN) ./scripts/proxy/hooks/pre_start.sh $(1)/etc/mynet/scripts/proxy/hooks/
	$(INSTALL_BIN) ./scripts/proxy/hooks/post_start.sh $(1)/etc/mynet/scripts/proxy/hooks/
	$(INSTALL_BIN) ./scripts/proxy/hooks/stop.sh $(1)/etc/mynet/scripts/proxy/hooks/

	# --- Plugin 钩子按插件布局**随包直接落盘**（不再由 postinst cp）---
	# opkg 先 unpack 全部包、再 configure（实测输出：两条 Installing 在前，两条
	# Configuring 在后）。钩子作为数据文件落地 ⇒ agent 的 postinst 起服务时
	# run_plugin_hooks 必然能找到它们，从根上消除「luci postinst 补钩子晚于 agent
	# 起服务」的竞态（2026-10-11 升 .182 实测：代理静默没起，fwmark/路由表缺失）。
	$(INSTALL_DIR) $(1)/etc/mynet/scripts/plugin/proxy
	$(INSTALL_BIN) ./scripts/proxy/hooks/pre_start.sh $(1)/etc/mynet/scripts/plugin/proxy/
	$(INSTALL_BIN) ./scripts/proxy/hooks/post_start.sh $(1)/etc/mynet/scripts/plugin/proxy/
	$(INSTALL_BIN) ./scripts/proxy/hooks/stop.sh $(1)/etc/mynet/scripts/plugin/proxy/
	$(INSTALL_BIN) ./scripts/proxy/route_policy.sh $(1)/etc/mynet/scripts/proxy/
	$(INSTALL_BIN) ./scripts/proxy/dns_split.sh $(1)/etc/mynet/scripts/proxy/

	# --- Proxy IP sources (bundled default lists, do not overwrite if already exist on device) ---
	$(INSTALL_DIR) $(1)/etc/mynet/conf/proxy/proxy_sources
	[ -f ./root/etc/mynet/conf/proxy/proxy_sources/interip.txt ] && \
		$(INSTALL_DATA) ./root/etc/mynet/conf/proxy/proxy_sources/interip.txt \
			$(1)/etc/mynet/conf/proxy/proxy_sources/ || true
	[ -f ./root/etc/mynet/conf/proxy/proxy_sources/chinaip.txt ] && \
		$(INSTALL_DATA) ./root/etc/mynet/conf/proxy/proxy_sources/chinaip.txt \
			$(1)/etc/mynet/conf/proxy/proxy_sources/ || true

	# --- GFW list (bundled default, do not overwrite if already exist on device) ---
	$(INSTALL_DIR) $(1)/etc/dnsmasq.d
	[ -f ./root/etc/dnsmasq.d/gfwlist.conf ] && \
		$(INSTALL_DATA) ./root/etc/dnsmasq.d/gfwlist.conf \
			$(1)/etc/dnsmasq.d/ || true

	# --- Runtime scripts: tools (optional diagnostics) ---
	$(INSTALL_DIR) $(1)/etc/mynet/scripts/tools
	$(INSTALL_BIN) ./scripts/tools/check_openwrt_masq.sh $(1)/etc/mynet/scripts/tools/
	$(INSTALL_BIN) ./scripts/tools/verify_gnb_es_orphan.sh $(1)/etc/mynet/scripts/tools/
	$(INSTALL_BIN) ./scripts/tools/diagnose_network.sh $(1)/etc/mynet/scripts/tools/
	$(INSTALL_BIN) ./scripts/tools/optimize_gnb_conntrack.sh $(1)/etc/mynet/scripts/tools/

	# --- curl TLS fix helper ---
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./root/usr/sbin/mynet-fix-curl $(1)/usr/sbin/

	# --- heartbeat cron script (替代 mynetd) ---
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./scripts/shell/heartbeat.sh $(1)/usr/bin/mynet-heartbeat

	# --- Deploy firewall.mynet 到 scripts/（平台防火墙正本；新 init 也调它）---
	# route.mynet 已退役：路由唯一路径 = 桥 → Go apply --auto（O1-③）
	$(INSTALL_DIR) $(1)/etc/mynet/scripts
	$(INSTALL_BIN) ./scripts/runtime/firewall.mynet \
		$(1)/etc/mynet/scripts/

	# --- Runtime directories (empty, needed at runtime) ---
	$(INSTALL_DIR) $(1)/etc/mynet/logs
	$(INSTALL_DIR) $(1)/etc/mynet/driver/gnb

	# --- LuCI menu.d (ucode-based LuCI route registration) ---
	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-mynet.json \
		$(1)/usr/share/luci/menu.d/

	# --- rpcd ACL ---
	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-mynet.json \
		$(1)/usr/share/rpcd/acl.d/

	# --- i18n translations ---
	# ⚠️ 不要写 $(basename)/$(dirname) —— GNU make 会先当内建函数吃掉。
	# 用 sed 从路径截 lang。
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	for pofile in $(CURDIR)/po/*/mynet.po; do \
		[ -f "$$$$pofile" ] || continue; \
		lang=$$$$(echo "$$$$pofile" | sed 's|.*/po/||;s|/.*||'); \
		python3 $(CURDIR)/tools/po2lmo.py "$$$$pofile" \
			$(1)/usr/lib/lua/luci/i18n/mynet.$$$$lang.lmo; \
	done
endef

define Package/luci-app-mynet/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# Clean up legacy _src directory from older versions
rm -rf /etc/mynet/scripts/_src
# 服务登记**不在本包**：由 mynet-agent 的 postinst 调 `mynet install`
# （登记唯一 owner；本包不写 init、不 enable/start）。
# plugin/proxy 钩子改为随包落地（见 install 段），**不再在这里 cp** —— postinst
# 晚于 agent 的 postinst 执行，那时服务已经起过、run_plugin_hooks 找不到钩子，
# 代理就静默没起（2026-10-11 升 .182 实测：fwmark/路由表缺失、隧道正常）。
# Clear LuCI cache
rm -rf /tmp/luci-*
exit 0
endef

define Package/luci-app-mynet/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# 服务注销归 mynet-agent 的 prerm（`mynet uninstall`），本包不动服务
# Remove legacy heartbeat cron entry
if [ -f /etc/crontabs/root ]; then
    sed -i '/mynet-heartbeat/d' /etc/crontabs/root
    /etc/init.d/cron reload 2>/dev/null || true
fi
exit 0
endef

$(eval $(call BuildPackage,luci-app-mynet))

# ── E-5：mynet_agent OpenWrt 产物（瘦构建 mynetd，无 embed WebUI）──
define Package/mynet-agent
  SECTION:=net
  CATEGORY:=Network
  TITLE:=MyNet agent (mynetd transport-only)
  DEPENDS:=+libc
  # ⚠️ **不设 PKGARCH:=all**。本包装的是**编译产物** mynetd，架构相关：
  # 设成 all 会让同一个 ipk 声称适配 mips/mipsle/arm/mips64 等所有架构，
  # opkg 不拦、装上去运行期才崩。留空即按目标架构出包（ipk 文件名带 arch 后缀）。
  # 对比：luci-app-mynet 是纯 Lua/JS 壳，那个 PKGARCH:=all 是对的。
endef

define Package/mynet-agent/description
  mynetd 纯通信层（心跳/WS/命令分派）+ mynet L6 执行器（apply 唯一写入者）。
  OpenWrt 命令执行走 lua -e（MYNET_EXECUTOR=lua），路由落盘仍调 mynet apply。
  产物名 mynet_agent_openwrt_*（E-8）。
endef

define Package/mynet-agent/install
	$(INSTALL_DIR) $(1)/usr/sbin
	# ⚠️ 这里**不能**用 `[ -f ./files/mynetd ] && … || true` 兜底。
	# 那样在缺文件时构建会静默成功，产出一个不含 mynetd 的空壳 ipk：
	# opkg 装得上、init 脚本也在，但 /usr/sbin/mynetd 不存在，服务起不来；
	# 而且构建日志里一行错误都没有 —— 正是 §7.1 D1 说的「静默失败即纸面达成」。
	# 缺文件必须**炸出来**并告诉人怎么补。
	@if [ ! -f ./files/mynetd ]; then \
		echo "ERROR: 缺 ./files/mynetd —— mynet-agent 包必须带二进制，拒绝产出空壳 ipk。" >&2; \
		echo "       补法：把目标架构的 mynetd 放到 ./files/mynetd" >&2; \
		echo "       来源：mynet_agent 的 make dist 产物（GOOS=linux）" >&2; \
		echo "       ⚠️ 注意 Go 的 mipsle 在 OpenWrt/ctl 侧叫 mipsel" >&2; \
		exit 1; \
	fi
	# mynet 是 L6 唯一写入者（route-apply-unification）。Lua 的 apply_routes
	# 会 shell 出去调它；缺了则路由装不上——同样不允许静默空壳。
	@if [ ! -f ./files/mynet ]; then \
		echo "ERROR: 缺 ./files/mynet —— 路由唯一写入者是 mynet apply，拒绝产出空壳 ipk。" >&2; \
		echo "       补法：把目标架构的 mynet 放到 ./files/mynet（与 mynetd 同一 dist）" >&2; \
		exit 1; \
	fi
	$(INSTALL_BIN) ./files/mynetd $(1)/usr/sbin/mynetd
	$(INSTALL_BIN) ./files/mynet $(1)/usr/sbin/mynet
	# init 不再随包（mynet install 从 agent 内嵌模板写出，见 O1）
endef

define Package/mynet-agent/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# TUN 模块（ipk 已声明 kmod-tun，这里兜底）
modprobe tun 2>/dev/null || true
# 服务装配**委托 `mynet install`**：写内嵌 init(/etc/init.d/{mynet,mynetd}) + env + UCI zone 并 enable/start。
# 包只落文件，不自己写 init —— 合同「系统登记只有一个 owner」。
GW="$${MYNET_GATEWAYS:-wss://gw.mynet.club/v1/node/connect}"
if [ -x /usr/sbin/mynet ]; then
	/usr/sbin/mynet install --gateways "$$GW" --prefix /usr --home /etc/mynet || \
		echo "mynet install 失败，请手工执行：mynet install --home /etc/mynet --gateways $$GW" >&2
else
	echo "缺 /usr/sbin/mynet —— 服务未装配" >&2
fi
# 摘掉旧版遗留的 cron 心跳（防双心跳）
if [ -f /etc/crontabs/root ]; then
	sed -i '/mynet-heartbeat/d' /etc/crontabs/root
	/etc/init.d/cron reload 2>/dev/null || true
fi
exit 0
endef

define Package/mynet-agent/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# 停服务并清自身登记委托 `mynet uninstall`；--keep-bin：二进制在 /usr/sbin 由 opkg 删
[ -x /usr/sbin/mynet ] && /usr/sbin/mynet uninstall --home /etc/mynet --keep-bin 2>/dev/null || true
exit 0
endef

$(eval $(call BuildPackage,mynet-agent))
