# 本仓不产出 ipk（出包 SSOT 在 mynet_agent）

**OpenWrt 包的构建与发布只有一个来源**：`mynet_agent/.github/workflows/build_openwrt.yml`
（官方 SDK 24.10 编 `luci-app-mynet` + `mynet-agent` 两个 ipk，矩阵 x86/64 · armsr/armv8 · ramips/mt7621）。

## 为什么这里删掉了 `release.yml`

原先本仓有一个**手搓 BSD-ar ipk** 的 workflow（`softprops/action-gh-release`）。它：
- 把 `scripts/runtime/rc.mynet` 装成 `/etc/init.d/mynet` —— 与「init 单一来源 = `mynet install` 写内嵌模板」冲突（O1）；
- 装 `mynet-heartbeat` cron 脚本 —— 属 O0 §F13 已下架的独立心跳；
- **不装** rpcd ucode 桥 `mynet.uc` —— 产出的包缺 O2 管理桥；
- 且该仓无 tag，此 workflow **从未实际跑过**。

两套出包路径 = 漂移（O6 禁：空包、私有仓浮动 HEAD、复制树）。故退役，出包一律走 SDK 路径。

## 本仓的职责

LuCI 壳（`luasrc/`、`htdocs/`）+ rpcd 桥（`luasrc/usr/lib/rpcd/ucode/mynet.uc`）+ 包定义（`Makefile`）。
`Makefile` 供 SDK 的 `package/<pkg>/compile` 调用；文件清单与安装语义以其为准。
