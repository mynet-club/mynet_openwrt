# MyNet OpenWrt Runtime

本目录是 MyNet 在 OpenWrt 上的运行时脚本源码。**当前只剩 `firewall.mynet` 一件。**

## 目录结构

```
scripts/runtime/
└── firewall.mynet      # 防火墙/zone/NAT 管理（平台正本）
```

## 部署后的系统路径

```
/etc/mynet/scripts/firewall.mynet       ← firewall.mynet（Makefile 安装）
/etc/init.d/{mynet,mynetd}              ← 由 `mynet install` 从 agent 的内嵌模板写出，不在本仓
```

## 职责边界（2026-10-11 收口，O1-③）

| 能力 | 归属 | 说明 |
|---|---|---|
| **路由 / 防火墙应用**（读 bundle → 装 OS 路由/防火墙） | **Go**（跨平台，非 OpenWrt 专有） | `mynet apply --auto`；LuCI 经桥的 `route-apply` 调它 |
| **出口/分流策略** | **Go** | `ProxyPolicy` + `planProxy` |
| **UCI/fw4 细节**（zone/forwarding/masq、`uci commit`、fw4 reload） | **本目录 `firewall.mynet`** | 平台专属，LuCI 只调它（不再内联 uci/nft） |
| **服务启停** | **procd**（`/etc/init.d/mynet`） | init 由 `mynet install` 写；Go 只下令 |

### firewall.mynet 子命令

```
firewall.mynet install | uninstall | start | stop | restart | status
firewall.mynet commit                       # uci commit firewall && /etc/init.d/firewall reload
firewall.mynet nat outbound|inbound 0|1     # 出站 NAT(zone masq) / 入站 NAT(mynet→lan 转发)
```

> `nat` / `commit` 是页面 NAT / fw-reload 按钮的落点；UCI 细节留在这里，页面不直写。

## 已退役（别再当遗留捡回来）

- `route.mynet` —— 本是 `mynet apply` 的薄壳，已由桥直连 `apply --auto` 取代
- `modules/{route,firewall}.sh` —— `route.mynet` 的 guts
- `rc.mynet` / `rc.mynet.procd.snippet` / `mynetd.init` —— 旧 Lua init；现由 `mynet install` 从 agent 内嵌模板写出

## 相关文档

- [OpenWrt VPN 跨网段互通设计](../../docs/openwrt_gw.md)
- 生命周期合同 / O0 操作矩阵（`mynet_ctl/docs/knowledge-base/spec/`）
