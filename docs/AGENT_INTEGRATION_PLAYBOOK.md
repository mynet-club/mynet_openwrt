# OpenWrt Agent 接入实施规划

> 2026-10-10。状态：现状取证与规划完成；运行时迁移尚未实施。
> 本文是 OpenWrt 平台实施正本，承接知识库 `dev-plan.md` 的 E-1…E-6 和 agent V1 Playbook 的 P5，不新增一套业务规范。
> 范围：仓库代码、打包与已有设备报告。本文没有重新登录设备、触发 CI 或查询线上发行接口；历史实机报告与本轮验证分开记。

> 跨平台前置：后续安装/接口分层、mynet 条件编译与升级合同遵循 [跨平台实施规划](../../mynet_ctl/docs/knowledge-base/spec/platform-lifecycle-build-playbook.md)；全 workspace 当前问题见 [审查报告](../../mynet_ctl/docs/knowledge-base/workspace-review-20261010.md)。O1/O6 不再只在 OpenWrt 内部修一套安装逻辑。

## 1. 产品定位与实施选择

OpenWrt 上的 MyNet 是路由器内的网络服务：用户从 LuCI 管理，节点经统一 agent 控制链运行，路由器已有网络服务继续由 OpenWrt 管理。

用户包括路由器本地管理员和拥有 MyNet 节点的用户，两种权限不互相替代。首个参考场景是隔离 OpenWrt 24.10 测试环境中的 GNB 节点：安装、接入、同步、启动、状态、停止、重启恢复。先验证 x86_64 或既有 armsr/armv8 测试环境，再扩展到 MT7621；主路由 192.168.8.1 是后续迁移对象，不是开发试验场。

**部署身份（2026-10-10 用户确认）：.178 是公司节点，承担用户当前网络的公司主路由；.182 是家里的旁路由。** 两者不是同一局域网的主/旁路组合，不能把 .182 当作当前公司网络的低风险测试机。两台现网设备均需各自迁移窗口与恢复通道。

本规划采用以下默认实施选择，属于待实施设计，不冒充已生效规则：

- 常规设备统一使用无 WebUI embed 的 mynetd；本地用户入口使用 LuCI/rpcd/ubus。
- localapi 保持设备内部回环接口 `127.0.0.1:8096`，不向 LAN 开放；本轮不引入 Unix socket。
- 身份、配置上下文、密钥、bundle 校验与投影复用 Go `mynet`；系统执行按能力装配 Go 或 OpenWrt 适配器。已有 Lua 系统能力按项迁移，不能一次整树删除。
- 不立项另一套完整 Lua 通信 agent。先测资源，再决定极弱设备能否支持、支持哪些能力；现有 Lua 路径仍需 Go，不能宣传为无 Go 版本。
- 包交付依赖；`mynet install` 负责主机准备、服务与必要的空 netifd 登记；实际 TUN 由驱动生命周期创建，绑定接口和授权后的 route/fw/NAT 归 apply。安装器调用统一安装实现，不自行复制系统操作；无有效节点配置时不开放 forwarding/masq。
- mynet 的系统实现按 Windows/Darwin/Linux 条件编译；OpenWrt 用 `linux && openwrt` 的专用后端，运行期能力探测保留。跨平台 H0–H2 为 O1 前置，H4 为 O6 前置。
- 初版完整验收以 GNB 为先；WireGuard 保持已有接口和数据，不凭 init 中有分支就声明支持完成。
- 不新增云端扫码/设备码绑定协议、通用任务平台、Acceleration 模型，不重做桌面 GUI，不改 gateway 鉴权职责。
- 旧 guest/离线、密钥导入、配置导出和诊断能力先登记并保留；本次不默默下架。

## 2. 当前基线与证据

本轮 HEAD：agent `50c1b58`；OpenWrt `f7c956e`；ctl `084496c`；API `76e1214`。agent 与 ctl 核对时工作树干净。OpenWrt 已有用户变更：README 将 mynet_back 改为 mynet_api，另有未跟踪 `UPGRADE_PLAN_192_168_8_1.md`；本规划不覆盖、不提交这些变更。

下表路径相对 workspace `mynet-club/`。结论均为代码静态取证，除非另标验证方式。

| 方面 | 当前事实与影响 | 证据 |
|---|---|---|
| 用户入口 | LuCI controller 直接调用 auth/node/proxy 业务，尚不是 agent 薄壳 | `mynet_openwrt/luasrc/controller/mynet.lua:543,880,1298,1338,1377,2101` |
| ubus | `call_localapi` 返回 bridge stub；Makefile 没有安装该 ucode 文件；ACL 没有 mynet 对象授权 | `mynet_openwrt/luasrc/usr/lib/rpcd/ucode/mynet.uc:6`；`mynet_openwrt/Makefile` install 段；`root/usr/share/rpcd/acl.d/luci-app-mynet.json` |
| 执行器装配 | `MYNET_EXECUTOR=lua` 同时替换 localapi Ops 和命令执行器，不仅替换系统操作 | `mynet_agent/cmd/mynetd/main.go:126-129`；`cmd/mynetd/executor_lua.go:39` |
| 接入合同断层 | connect 需要 `initialized/mode/active` 及 keys ensure/sync、pull；Lua config 分支忽略子命令，只返回 node_id/running/vpn_type/interface | `mynet_agent/mynetd/localapi/connect_api.go:48-88` 对照 `cmd/mynetd/executor_lua.go:271-285`。静态可证明不满足字段合同；本轮未跑真实 Lua connect |
| apply 合同断层 | Lua apply 分支只区分 clear，其余都走 apply_routes；不能把 `apply --active` 当作 Go 的运行配置投影 | `mynet_agent/cmd/mynetd/executor_lua.go:180-193` 对照 `mynetd/localapi/connect_api.go:88-91` |
| Lua 并非独立轻量版本 | detector 和路由应用都转调 mynet；ipk 明确要求 mynet、mynetd 两个二进制 | `cmd/mynetd/executor_lua.go:218-232`；`mynet_openwrt/luasrc/model/mynet/node.lua:1726-1752`；`Makefile:212-219` |
| 双 init 来源 | ipk 的 mynetd.init 未加载 env；installer 的内嵌版本加载 env。ipk rc.mynet 与 installer 内嵌 init 的双驱动、接口与启动后等待行为不同 | `mynet_openwrt/scripts/runtime/mynetd.init:9-16` 对照 `mynet_agent/mynet/units/openwrt_mynetd.init:13-20`；两仓 mynet init |
| 路径不一致 | installer 校验 prefix/sbin，Unix 默认 /opt/mynet；ipk 落 /usr/sbin | `mynet_agent/mynet/cmd_install_openwrt.go:38-44`；`mynet/prefix_unix.go:8-13`；`mynet_openwrt/Makefile:218-219` |
| 心跳未收窄 | postinst 默认加入 cron。Lua 在 mynetd 存活时跳过心跳，但 cron 仍包含 peer-heal；不能断言必双报，也不能直接删脚本 | `Makefile:155-161`；`luasrc/model/mynet/system.lua:644-647,730-732`；`scripts/shell/heartbeat.sh:62` 起 |
| 生命周期多入口 | Lua service 分派已走 init；LuCI 仍有直接 start_gnb/stop_gnb API，node.lua 仍有 spawn 路径 | `cmd/mynetd/executor_lua.go:194-211`；`controller/mynet.lua:1338-1359`；`model/mynet/node.lua:1282` |
| Proxy 两条路径 | Lua 自读 proxy_role.conf/proxy_route.conf；统一出口许可、版本和撤销需接 Go Cloud 应用路径 | `mynet_openwrt/luasrc/model/mynet/proxy.lua:16,60,411,439`；`mynet_agent/shared/domain/bundle_envelope.go:56,420`；知识库 `spec/proxy-permission-loop-playbook.md` |
| 出包有配方但未闭环 | 独立 workflow 无 embed，出 SDK ipk，但 checkout 私有 mynet_openwrt-V2 且只上传 Actions artifact；普通 dist 没有 openwrt，恒 embed | `mynet_agent/.github/workflows/build_openwrt.yml:35-40,83-96,124-129`；`Makefile:76,112` |
| 分发合同 | ctl 能解析 ipk，但 openwrt 默认扩展名仍是 tgz；SDK 包名与 ctl 外部分发名是两层合同 | `mynet_ctl/app/Domain/Release/Services/ReleaseDomainService.php:34,171-176,198` |
| 重复树分叉 | agent/openwrt 与独立仓在 5 个 Lua/视图文件和 4 个 shell 文件上不同；文档已指向独立仓 | 本轮 `diff -qr`：node/proxy/util.lua、login/proxy.htm；pre_start/stop hook、route_policy、firewall.mynet。不得盲删任一份 |
| 测试边界 | OpenWrt test 只运行打包不变量；connect 测试注入 fake Ops，无法发现实际 Lua config 合同断层 | `mynet_openwrt/Makefile.guard:20-22`；`mynet_agent/mynetd/localapi/connect_api_test.go:25-42` |

历史设备报告：`UPGRADE_PLAN_192_168_8_1.md` 记录 .178 为主路由、rootfs 可用约 45.7M、尚无 Go agent、存在手工回程与防火墙规则；`TEST_REPORT_OPENWRT_UI_INTERACTION_20260929.md` 记录 QEMU 联调。本文引用这些报告，不将其视为 10-10 本轮实机复测，也不沿用旧缺陷“待修”状态覆盖新代码。

需要重点审查的已有代码：内嵌 init 的 gnb_es 清理条件包含 `exe匹配 OR PPID=1`（`mynet_agent/mynet/units/openwrt_mynet.init:137-145`），仅 PPID=1 不能证明属于本节点；必须在进程归属工作包中验证和收窄，不能因注释称“精确”而放行。

## 3. 冻结边界与合同

```text
浏览器 → LuCI 会话 → rpcd/ubus 白名单方法 → 回环 localapi
                                             ↓
                                  mynetd：通信与编排
                                             ↓
                         mynet：身份/配置/校验/投影/系统执行
                                             ↓
                       OpenWrt 适配器：procd/netifd/fw4

节点面：mynetd → gateway → mynet_api（既有身份与合同）
```

- NodeID 始终为十进制字符串，不转 Lua number；不重新分配现存节点、地址或密钥。
- 本地管理员权限由 LuCI/rpcd 校验；云端属主与授权由 API 校验。LuCI root 不获得其他云端节点权限，云端登录也不自动取得路由器本地管理权限。
- 浏览器只访问 LuCI 同源接口。桥使用固定回环目标和路径，不能接收任意 URL、任意 argv、shell 字符串或文件路径；不提供通用 relay 透传方法。
- 身份/配置原样复用当前 `config status/active/keys/pull` 与 connect 流程及响应；不创建第二套 Lua credential/context 权威。
- bundle 复用现有 schema/checksum/generation；接口名遵循 TunDevice 冲突判据，Cloud 应用复用现有单调版本与回滚逻辑。无有效新许可不得由旧 conf 自动恢复出口。
- `network.proxy` 仍只有出口许可 enabled/acl；消费端 DNS/出口选择/分流是 Local 策略，不塞回云端合同。无许可、空白名单开放、撤销是不同状态，按已有小闭环解释。
- 本机响应沿现有 success/message/data/stage/steps/code 等字段逐端点登记，不另建全项目错误码体系。rpcd 错误只表达会话/ACL/传输失败；业务响应保留原义，不能把 HTTP 失败转成成功。
- procd 是唯一隧道生命周期控制者；重启/停止不得走脱离 procd 的 spawn/kill。peer-heal 留在执行器或平台服务，不给 mynetd 添加 OS 探测。
- MyNet 只管理其拥有的隧道、路由、规则与 include；LAN/WAN 默认路由、用户手工回程、dnsmasq 和非 MyNet 防火墙规则不纳入自动清理。
- 本轮没有新增身份 TTL 或随机 ID 算法；沿用既有用户会话有效期与节点身份规则。配置按现有缓冲模式处理，不新增流式 body 合同。

## 4. 工作包与顺序

执行默认为单执行者；下表的可并行性仅表示未来分工边界，不授权启动子代理。每包交付独立变更、相关测试结果、限制和后继依赖，不夹带其他仓清理。

| 包 | 目标、归属与修改边界 | 输入/输出与验收 | 前置 / 禁区 |
|---|---|---|---|
| O0 现状与接口锁定 | OpenWrt docs + ctl 导航；agent 合同 fixture | 清点全部 LuCI 用户操作及其调用者；按保留/迁移/移除登记。脱敏固定 fixture：未初始化、已接入、离线、过期会话、版本冲突、出口无许可/开放/白名单/撤销。接口表记录具体路径、请求、响应、权限和资源上限 | 本文为 O0 的规划部分，操作全量表与 fixture 尚未交付；不修改业务行为 |
| O1 装配与执行合同 | agent cmd/mynetd、mynet installer/units；OpenWrt 打包 init | 把身份/config/keys/pull/apply-active 显式交给 Go；系统操作通过经过测试的能力路由进入 OpenWrt/procd，避免顶层 cmd 一刀切。init 单一源码，ipk 与 installer 生成物一致；prefix/home/bin/env 一致。交付实际执行器驱动的 connect 测试 | O0；禁静默 fallback、双写 credential、给 mynetd 加 OS 能力。不得用 execMynet 的 service 分支造成调用自身的循环 |
| O2 本地管理桥 | OpenWrt rpcd ucode/ACL/包安装；必要的 localapi 适配 | 第一批方法限定状态、接入状态、选节点/接入、同步、service、日志/诊断；逐方法冻结映射，明确读取和写入 ACL。登录信息仅走允许的既有登录端点；拒绝任意 relay/argv。daemon 不在、超时、会话拒绝可区分；实际加载对象、实际调用回环端点 | O0/O1；禁把 LAN Host 加入 localapi 白名单来绕过桥，禁私钥/system.json 原样开放 |
| O3 生命周期与规则归属 | agent units/mynet OpenWrt 网络适配；OpenWrt runtime/node/hooks | 停止直接 GNB API；procd 启停/崩溃/respawn/reload 后 tun、route、fw 均就绪。gnb_es 只按本实例归属清理。梳理 fw4 reload/hotplug 回放、gateway/bypass 策略，记录每项规则的创建者与清理者。peer-heal 冷却与启动宽限保留并测试后才摘 cron | O1；禁按名字或仅 PPID=1 清理进程；禁重写普通 LAN→WAN NAT、覆盖全局 DNS或扩大出口许可 |
| O4 统一配置与 Proxy | agent Cloud/Local apply + OpenWrt proxy/hooks；API 仅在确认合同缺失时修改 | LuCI 与远程命令走相同 bundle 校验/投影路径；删除用户 JWT 参与后台节点同步。旧 proxy conf 转成 Local 意图，Cloud 出口许可只来自统一 bundle。保留 last-known-good，旧 generation 拒绝、撤销清理、失败关闭、无关规则保留 | O1/O3及既有 P4 合同；禁再写一套 Lua Cloud 授权引擎，不自动发明手工回程的新云模型 |
| O5 LuCI 用户流程 | controller/views/static；保留后逐页替换 | 最小流程：路由器登录→MyNet 登录/选现有设备或沿现有创建入口→接入→概览/诊断→停启。页面状态来自桥，显示未绑定/离线/配置处理中/失败等实际状态；长操作依据 steps/stage，超时后先查状态，不盲重试 | O2，写操作接 O3/O4；禁直接 auth/node/proxy 系统写入、假成功和独立心跳；guest 按兼容清单保留 |
| O6 可复现出包与分发 | agent workflow/build；OpenWrt Makefile；ctl release/tests | CI 固定两仓 SHA 与 SDK 版本，构建不 embed mynetd。ipk 运行包不依赖 LuCI；Lua 系统模块若仍需要，拆出明确 runtime 依赖。LuCI 包依赖运行包，不携带另一套 init/heartbeat。冻结 SDK 内部包名、ctl 外部文件名、显式 ipk 扩展名、版本/架构/float 映射、sha256/manifest；真上传→索引→下载→opkg 安装/升级/卸载 | O1，O3/O4 的文件归属稳定后收口；构建骨架可提前做。禁空包、私有仓浮动 HEAD、tgz 改后缀冒充 ipk。不能把 amd64 Go 字符串检查当成能力验收 |
| O7 隔离平台与资源验收 | OpenWrt debug/tests/docs；agent 必要修复 | GNB 全流程、ACL、重启/断网/恢复、fw4 reload、并发、撤销、数据面允许/拒绝、冷启动、升级回滚。采集空闲常驻 RSS、connect/apply 峰值、CPU、安装空间/临时空间、启动时间；测试一台实际弱设备后定支持范围 | O1…O6；QEMU 结果只能证明对应环境，不能代替 MIPS 实机资源证据；WG 独立验收，不借 GNB 通过 |
| O8 现网迁移与收尾 | 设备专属计划 + OpenWrt 文档/ctl 部署清单 | 先隔离与明确非关键设备；家庭旁路由 .182、公司主路由 .178 分别评估。校验备份可恢复、各自控制台通道、磁盘余量、固定产物；密钥/接口/对等参数/回程逐项比对。迁移验收后摘旧 cron/业务入口及过渡文件，观察重启与断网恢复 | O7/H5；不以旁路由身份自动指定 .182 为试验机，不以本规划授权现网切换；公司 .178 最后单独安排 |

依赖顺序：O0→O1→O2/O3；O3→O4；O2+O3/O4→O5；O6 骨架可与 O2/O3 交错进行，发行收口等 runtime 文件归属稳定；O1…O6→O7→O8。

第一实施批次只做 O0 的操作/合同表和 O1 装配一致性，不先美化 LuCI，也不升级主路由。复用既有测试，新增测试集中在实际 Lua/Go 分派断层、init 行为和越权拒绝。

## 5. 迁移与兼容策略

1. 先 diff 两份 OpenWrt 树并形成逐文件归属表。独立仓为平台正本；agent 只保留明确的引用或版本化集成方式。所有仅存在于复制树的修复先验证再搬，去重安排在 O6，不一刀切删除。
2. 新包安装不得预先修改网络和启动未绑定隧道。服务装配与接入明确分开；升级不得在 postinst 自动切换活动节点、密钥或 Cloud 出口状态。
3. 初始化/升级区分三种来源：旧 Lua 独立部署、现有混合 agent 部署、全新安装。写迁移标记与版本，重复迁移幂等；旧 schema/路径未知则停止并报告，不猜接口名。
4. 读取旧配置生成脱敏差异报告，然后经新投影生成候选文件；验证 node_id/公钥指纹/ifname/zip/crypto/mtu/UPnP 对等参数、路由与权限，再原子替换。私钥不输出 diff，不擅自生成新钥。现存私钥的导入/转换必须遵循 GNB 布局与现有命令合同。
5. 影子阶段只比较配置/规则计划，不起第二个隧道实例、不写第二套规则。隔离环境强制新路径通过后，选择单设备切换；完成验收再将该部署默认设为新路径。
6. Lua cron 退役前分离心跳与 peer-heal，并证明替代自愈有效；mynetd 崩溃由 procd 恢复，不自动启用旧 Lua 通信路径。旧路径仅作为完整部署回滚件。
7. 原有 guest/离线和导入导出由 O0 全量登记；若首次版本暂时保留旧实现，要明示适用模式，禁止它写在线节点的活动配置。未验证兼容时暂停该功能迁移，不能宣布迁移完成。
8. 主路由手工回程优先保持在 netifd/UCI 或原有本机归属内；是否云端表达是独立需求。不能因为 bundle 未包含就删除，也不能将缺少该路由直接等同于 agent 必须管理它。
9. 回滚恢复旧包/init/config/context 与 MyNet 自有规则，避免恢复全量 ruleset 覆盖其他并发改动；实际主路由按设备快照/恢复剧本执行。回滚软件不代表可以恢复已撤销的旧 Cloud 出口许可；无当前有效许可保持关闭。

## 6. 权限、数据与运行上限

- 桥读写按方法授权：状态/日志读取与接入/切换/密钥/启停分开；写请求校验 LuCI 会话与 RPC ACL，未登录/越权不触发 Ops。会话失效沿现有期限处理，不发明永久管理员 token。
- 浏览器登录请求由桥检查并转发现有本机登录路径，token/cookie 不进入 LuCI JS 或日志；API 会话放既有服务端存储，不能与 Lua credential 双份回写。
- 桥为 inspect-body（校验字段）后有限透传；Go 执行器为 transform-body（配置投影）；日志只读脱敏快照。任何组件不采集、不保留用户数据流 payload。禁止外发原始私钥、credential、bundle、完整 system.json 或好友图。
- 调用使用参数化 HTTP 客户端或安全 argv，不拼 shell；目标固定为回环 mynetd。日志参数不能变成任意读文件入口，stdout/stderr 不含 Lua 源码/秘密。
- O0 必须量出并写入方法表：最大请求/响应/日志大小、桥与 daemon 的超时、rpcd 可承受的调用时长。当前执行器有 60s 上限；不能假设 LuCI/rpcd 同样能等 60s。接入采用有界同步或既有结果查询，超时需明确“结果未知，请查状态”，不宣称失败后自动重复密钥或切换操作。
- 记录 operation/request 标识（复用既有或最小增加）、操作者类别、方法、节点脱敏标识、stage、generation、耗时和结果；证据不保存输入密码、cookie、token、私钥。凭证访问只走 crt/crtvault。
- 并发保护覆盖 LuCI 写入、CLI、后台配置通知和启动恢复；现有 localapi configMutation 只是进程内入口保护，不能当作跨进程事务。O1/O4 验证现有文件锁/版本闸的实际覆盖，再补缺口，拒绝产生半投影或以旧授权覆写新撤销。

## 7. 验证门禁与支持矩阵

| 门禁 | 必须证明 | 不能代替它的证据 |
|---|---|---|
| G0 合同 | 操作清单与字段/权限/错误 fixture 完整；两份代码差异处置明确 | README 架构图、旧台账勾选 |
| G1 运行时 | 真执行器处理 config/keys/pull/apply/service；失败清理、重放和并发可验证；包/init 与 installer 一致 | 全部 fake Ops 的 connect 测试、仅字符串断言 |
| G2 原生入口 | 实际 rpcd 注册；登录后读写可用、未登录/只读账号拒绝；daemon 缺失与超时可解释 | 返回 stub、只拿 root 手工调用 ubus |
| G3 系统与数据面 | procd 崩溃恢复、gnb_es 归属、hotplug/fw4 reload；授权流量允许、未授权拒绝、撤销和离线失败关闭，LAN/WAN/DNS/手工路由保留 | ping 通、服务 running、规则里能搜到字符串 |
| G4 分发 | 指定 SHA 从 SDK 真出 ipk→ctl 索引/下载→opkg 安装/升级/卸载；每个支持架构有安装证据 | Actions artifact、交叉编译、扩展名匹配 |
| G5 资源 | 包体/安装与迁移临时空间、常驻与峰值内存、CPU/启动数据；弱设备实测后才设支持下限 | Lua 语言标签、仅 Go 文件大小、QEMU 大内存配置 |
| G6 迁移 | 原身份不变、功能覆盖、备份恢复成功、重启/断网恢复与观察记录 | 复制文件完成、切换当天单次启停 |

初始候选支持矩阵：OpenWrt 24.10 x86/64 与 armsr/armv8、GNB。MT7621/mipsle softfloat 是下一验证目标，不能仅用 ctl 的 mipsel 标签省略 ABI 说明。ImmortalWrt、fw3、其他版本/target、WG、极弱设备分别记验证状态，未验证不在发行页宣称支持。

每次实施运行相关仓实际 check 入口：agent `make check`；OpenWrt `make -f Makefile.guard check` 并补真实 Lua 5.1/ucode/rpcd 行为测试；ctl 变更执行其 Makefile 门禁和发行测试；API 只有改代码时才跑对应及必要全量测试。工具缺失和 skip 记录为未验证，不能算通过。

## 8. 本轮验证与未验证事项

2026-10-10 本地执行：

- agent：`go test ./cmd/mynetd ./mynetd/localapi ./mynet -run 'OpenWrt|Lua|ConfigConnect' -count=1` 三包通过。注意现有接入测试名为 TestConnect*，此过滤条件不覆盖它们；不得凭本条声称 connect 验证完成。
- OpenWrt：`sh scripts/tools/check_agent_pkg.sh Makefile` 通过，包括真实执行从 Makefile 提取的缺件守卫；这是打包不变量验证，不是 SDK 出包。
- agent：`go test ./cmd/mynetd ./mynetd/localapi ./mynet -count=1` 三包通过（2.048s / 0.382s / 5.942s）；它覆盖既有 TestConnect*，仍非实际 OpenWrt Lua/ubus 测试。

本轮未执行：设备 SSH、QEMU 新部署、LuCI 浏览器操作、SDK CI、线上 ctl 查询、资源测量、真实允许/拒绝流量、现网升级。历史报告中的线上 latest 与磁盘数据仅作实施前复核清单。

## 9. 完成定义与记录方式

O0…O8 分别登记“规划/代码通过/隔离环境通过/对应实机通过/发行通过”，禁止合并成一个已完成勾选。原 E 台账历史标记保持，但本文明确它不能证明当前闭环；取得行为证据后再更新其状态与上位 P5/M4。

每包交付：文件/接口、保留与改变的行为、迁移/权限/数据影响、命令与结果、设备/SDK/源码版本、失败与回滚、限制、后继依赖。证据脱敏后保存于本仓 docs，生态级状态与指针回写 ctl 知识库，不重复复制规划正文。

平台收口条件：LuCI 到 agent 的接入及日常控制可用；只有一条通信路径和一套身份/Cloud 规则权威；procd 生命周期与 MyNet 规则归属成立；发行链可复现；至少参考环境和声明支持设备完成行为与资源验收；旧部署可迁移可恢复。未达到这些条件，不勾 M4/M6，也不将主路由当作完成证明。
