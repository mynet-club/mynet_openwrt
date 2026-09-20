include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-mynet
PKG_VERSION:=2.1.8
PKG_RELEASE:=1

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

	# --- Init script (rc.mynet → /etc/init.d/mynet) ---
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./scripts/runtime/rc.mynet $(1)/etc/init.d/mynet

	# --- Runtime scripts: proxy ---
	$(INSTALL_DIR) $(1)/etc/mynet/scripts/proxy/hooks
	$(INSTALL_BIN) ./scripts/proxy/proxy.sh $(1)/etc/mynet/scripts/proxy/
	$(INSTALL_BIN) ./scripts/proxy/hooks/pre_start.sh $(1)/etc/mynet/scripts/proxy/hooks/
	$(INSTALL_BIN) ./scripts/proxy/hooks/post_start.sh $(1)/etc/mynet/scripts/proxy/hooks/
	$(INSTALL_BIN) ./scripts/proxy/hooks/stop.sh $(1)/etc/mynet/scripts/proxy/hooks/
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
	$(INSTALL_BIN) ./scripts/tools/diagnose_network.sh $(1)/etc/mynet/scripts/tools/
	$(INSTALL_BIN) ./scripts/tools/optimize_gnb_conntrack.sh $(1)/etc/mynet/scripts/tools/

	# --- curl TLS fix helper ---
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./root/usr/sbin/mynet-fix-curl $(1)/usr/sbin/

	# --- heartbeat cron script (替代 mynetd) ---
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./scripts/shell/heartbeat.sh $(1)/usr/bin/mynet-heartbeat

	# --- Deploy route.mynet / firewall.mynet to scripts/ (fixed path) ---
	$(INSTALL_DIR) $(1)/etc/mynet/scripts
	$(INSTALL_BIN) ./scripts/runtime/route.mynet \
		$(1)/etc/mynet/scripts/
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
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	for pofile in $(CURDIR)/po/*/mynet.po; do \
		lang=$$(basename $$(dirname $$pofile)); \
		python3 $(CURDIR)/tools/po2lmo.py $$pofile \
			$(1)/usr/lib/lua/luci/i18n/mynet.$$lang.lmo; \
	done
endef

define Package/luci-app-mynet/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
# Clean up legacy _src directory from older versions
rm -rf /etc/mynet/scripts/_src
# Stop and disable Go mynetd (replaced by cron heartbeat)
pkill -x mynetd 2>/dev/null || true
# Enable and load tun module
modprobe tun 2>/dev/null
# Sync proxy hooks -> plugin/proxy/ (rc.mynet calls scripts/plugin/<plugin>/<hook>.sh)
mkdir -p /etc/mynet/scripts/plugin/proxy
for _h in pre_start post_start stop; do
    _src="/etc/mynet/scripts/proxy/hooks/$${_h}.sh"
    _dst="/etc/mynet/scripts/plugin/proxy/$${_h}.sh"
    [ -f "$$_src" ] && cp -f "$$_src" "$$_dst" && chmod 0755 "$$_dst"
done
unset _h _src _dst
# Install firewall zone
MYNET_HOME=/etc/mynet sh /etc/mynet/scripts/firewall.mynet install 2>/dev/null
# Clear LuCI cache
rm -rf /tmp/luci-*
# Enable mynet service
/etc/init.d/mynet enable 2>/dev/null
# Setup heartbeat cron (every 5 minutes, replaces mynetd)
mkdir -p /etc/crontabs
if ! grep -q 'mynet-heartbeat' /etc/crontabs/root 2>/dev/null; then
    echo '*/5 * * * * /usr/bin/mynet-heartbeat' >> /etc/crontabs/root
fi
/etc/init.d/cron reload 2>/dev/null || true
exit 0
endef

define Package/luci-app-mynet/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
/etc/init.d/mynet stop 2>/dev/null
/etc/init.d/mynet disable 2>/dev/null
# Remove heartbeat cron entry
if [ -f /etc/crontabs/root ]; then
    sed -i '/mynet-heartbeat/d' /etc/crontabs/root
    /etc/init.d/cron reload 2>/dev/null || true
fi
exit 0
endef

$(eval $(call BuildPackage,luci-app-mynet))
