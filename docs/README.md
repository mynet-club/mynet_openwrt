# mynet_openwrt 文档

> **本目录是 OpenWrt 平台文档的 SSOT（正本）。**
> `mynet_agent/openwrt/docs/` 曾是这里的复制，2026-10-01 已去重为指针——
> 改文档只改这里。

| 文档 | 内容 |
|------|------|
| [architecture.md](architecture.md) | 架构设计 |
| [build.md](build.md) · [deploy.md](deploy.md) | 构建 / 部署 |
| [openwrt_gw.md](openwrt_gw.md) | 网关与连通 |
| [FLOWS.md](FLOWS.md) | 关键流程 |
| [bugs.md](bugs.md) · [TODO_key_import_verification.md](TODO_key_import_verification.md) | 已知问题 / 待办 |
| [TEST_PLAN_OPENWRT_UI_INTERACTION.md](TEST_PLAN_OPENWRT_UI_INTERACTION.md) 及 `TEST_REPORT_*` | 测试计划与报告 |
| [MACOS_*](MACOS_QEMU_SPLIT_ROUTING.md) · [MacOS_*](MacOS_Openwrt_IPSET_Proxy.md) | macOS 侧联调 |
| [UX_LUCI_VS_WEBUI_20260929.md](UX_LUCI_VS_WEBUI_20260929.md) | LuCI vs WebUI |
| [UPGRADE_PLAN_192_168_0_2.md](UPGRADE_PLAN_192_168_0_2.md) · [SESSION_NOTES_20260930.md](SESSION_NOTES_20260930.md) | 单次计划 / 会话笔记 |

**生态规则**见 `mynet_ctl/docs/knowledge-base/`（AGENTS.md · projects/mynet_openwrt.md）。

> ⚠️ 另注：`mynet_agent/openwrt/` 整棵树与本仓仍高度重复（代码已开始分叉），
> 清理工作见 CPI / 后续任务，不在文档去重范围内。
