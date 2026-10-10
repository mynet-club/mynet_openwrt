# O2 本地管理桥 —— 方法映射（冻结表）

> 2026-10-11。O2 交付物之一：**逐方法冻结映射**（path/verb/参数白名单/ACL 读写）。
> 依据：`mynet_agent/mynetd/localapi/` 的路由注册；**读端点包 `getOnly(...)`、写端点包 `s.withConfigMutation(...)`**
> （`config_api.go:25-35`、`server.go:83`）—— 这就是动词契约的权威来源。
> 桥落点：**`/usr/share/rpcd/ucode/`**（设备实证）；HTTP 客户端用 **`curl`**（设备在位，ipk DEPENDS 已声明）。

## 1. 第一批方法（状态 / 接入 / 选节点 / 同步 / service / 诊断）

| ubus 方法 | localapi path | 动词 | 参数白名单 | ACL | 备注 |
|---|---|---|---|---|---|
| `mynet.status` | `/api/v1/status` | GET | — | read | `server.go:77` |
| `mynet.node-status` | `/api/v1/node-status` | GET | — | read | `wizard.go:109` |
| `mynet.nodes` | `/api/v1/nodes` | GET | — | read | `server.go:84` |
| `mynet.identity` | `/api/v1/config/identity` | GET | — | read | `config_api.go:29` |
| `mynet.runtime` | `/api/v1/config/runtime` | GET | — | read | `config_api.go:30` |
| `mynet.tenants` | `/api/v1/config/tenants` | GET | — | read | `config_api.go:26` |
| `mynet.wizard-state` | `/api/v1/wizard/state` | GET | — | read | `wizard.go:106` |
| `mynet.logs` | `/api/v1/logs` | GET | `lines?`（数字上限） | read | `server.go:79` |
| `mynet.metrics` | `/api/v1/metrics` | GET | — | read | `server.go:80` |
| `mynet.connect` | `/api/v1/config/connect` | POST | `mode,node_id,tenant` | write | `config_api.go:32` |
| `mynet.switch-node` | `/api/v1/nodes/switch` | POST | `node_id` | write | `server.go:83` |
| `mynet.sync` | `/api/v1/config/apply` | POST | `active,auto` | write | `config_api.go:35` |
| `mynet.keys-sync` | `/api/v1/config/keys` | POST | `action,pub_hex` | write | `config_api.go:28`（**只进不出：不回私钥**） |

## 2. 明确**不做**（桥的安全边界）

- **不做任意 relay**：ubus 方法只走**上表固定映射**；不带自由 path/argv 参数，不把 `ubus` 参数拼进 shell。
- **不原样开放 `system.json`**（`server.go:78` 的 `/api/v1/system.json` **不映射**）；确需字段时由 status/runtime 的既有响应给。
- **不返回私钥**：`config/keys` 只做写（导入/同步公钥），响应过滤。
- **登录只走既有端点**：`/api/v1/auth/login`、`/api/v1/wizard/{login,logout}`；桥不新增认证路径。
- **不把 LAN Host 加进 localapi 白名单**来绕过桥（O2 禁令）。

## 3. 错误分类（可区分）

| 情况 | 返回 |
|---|---|
| daemon 不在（8096 连不上） | `{ error: "daemon-unavailable" }` |
| 超时 | `{ error: "timeout" }` |
| 会话/鉴权被拒（401/403） | `{ error: "session-rejected", status: <code> }` |
| 其余非 2xx | `{ error: "upstream", status: <code>, body: <截断> }` |

## 4. 待确认（不猜，落码前核）

1. `withConfigMutation` 的**确切方法要求**（是否严格 POST；是否要 CSRF/token 头）。
2. `/api/v1/plugin/proxy`（`proxy_api.go:38`，未包 `getOnly`/`withConfigMutation`）的动词与入参。
3. **service 启停端点**：localapi 表里没有 service 端点 → 走 `/api/v1/command`（`server.go:81`，E-4 命令通道）还是本机 `mynet service`（执行器）——需读 `command` 的语义后定。
4. `connect` 的**字段名**（`connect_api.go` 未见 `json:` 标签导出，需读 handler 入参解析处）。

## 5. VM 实测记录（2026-10-11，.182 / ImmortalWrt 24.10 x86_64）

- `ubus list` → `mynet` 注册成功；`ubus -v list mynet` → 16 方法齐全、入参可见。
- 读方法实测返回真实数据（`runtime` 给出 `interface=gnb_tun_16`、`node_id=8283289760467957`）。
- 未知名方法由 rpcd 明确 `Method not found`。
- ACL 文件被 rpcd 接受（重启无报错）；内容 = 读 10 / 写 6。
- ✅ **入参类型 `String` 是 rpcd ucode 的标准渲染，不是缺陷**（无需重写）：
  - rpcd 的 ucode 插件里 `args: { <名>: <值> }` 的**值就是参数名本身**（非 libubus 类型关键字），rpcd 一律渲染成 `String`；
  - 设备自带插件的实证同此：`ddns.uc` 写 `args: { service_name: 'service_name' }`、`luci.wireguard` 写 `{ privkey: "String" }` —— 两者在 `ubus -v list` 上同为 `String`；
  - 参数语义（是否必填、取值范围）由 `.uc` 内自行校验（如 `lines` 走 `^[0-9]{1,4}$`、`action` 走白名单）。
- ✅ **会话态 ACL 正/负测试已做**（root 口令由用户提供，`.182` 实测）：
  - 正向：`session login` 取得 SID 后，`ubus call session access '{"ubus_rpc_session":"<sid>","scope":"ubus","object":"mynet","function":"<m>"}'` 对 **16 个方法全部返回 `access=true`**；
  - 负向：同一 SID 对**不在 ACL 的方法**（`drop-everything`、`shell`）返回 `access=false` —— 边界收得住；
  - ⚠️ 注意：`ubus` CLI 以 uid 0 直连会**绕过** ACL，不能用 `ubus call mynet …` 验权限，必须走 `session access` 判定。
- ✅ **静态一致性门禁**：`scripts/tools/check_bridge_acl.sh`（桥 16 方法 ⇄ ACL 读 10/写 6 ⇄ LuCI 客户端 `bridge.lua` 的 `M.METHODS`）**三方**逐项对齐，已挂进 `Makefile.guard` 的 `test` 目标；本机（BSD sed）与 Linux（GNU sed）双通，负例注入（缺项/等量替换）可红。
- ✅ **HTTP 路径实证（LuCI JS 的真实调用形态）**：`POST /ubus`（rpcd HTTP）带会话 SID 调 `["<sid>","mynet","status",{}]` → `result:[0,{...localapi 信封透传...}]`；越权方法 → `error:{code:-32002,"Access denied"}`。这坐实了「浏览器只访问 LuCI 同源接口 → rpcd ACL → 回环 localapi」整条链。

## 5b. O5 客户端接线（2026-10-11）

- 新增 **`luasrc/model/mynet/bridge.lua`**：页面**唯一**的本地读写入口（`M.call` + 逐方法包装），方法表冻结为与桥/ACL 同一份 16 项，未知方法在客户端先于 ubus 拒绝。
- **首个消费点**：`controller/mynet.lua:api_get_status` 附加 `bridge` 字段（独立 `pcall`，daemon 不在时不影响旧字段）。设备实测（`.182`）：
  - 模块：`lua -e require(...).status()` → `daemon=mynetd, success=true`（**Lua 5.1.5** 实机通过）；
  - 端点：`GET /cgi-bin/luci/admin/services/mynet/api/status` → 旧字段（`vpn_status`/`vpn_iface`/`zone`/`node_id`）**不变**，新增 `"bridge":{"daemon":"mynetd","listen":"127.0.0.1:8096","role":"transport-only"}`。
- 设备原 controller 与仓内 HEAD **逐字节一致**（无本地分叉），覆盖安全。
- **O5 剩余**：把 `index/node/service/proxy/guest` 等页面的读/写逐页改走 `bridge`（需浏览器验证 + 依 O0 操作全量表定取舍），并据此退役 Lua 的 `rc.mynet`/`route.mynet` 直连（O1-③ 解锁）。

### 实测暴露的系统性问题（归 O3，已两次实证）

**执行器「成功却回 exit status 1」**：
1. `service restart` —— 服务实际 running、tun UP，却回 `exit status 1`；
2. `config/apply`（写探针）—— `{"bin":"lua","argv":["apply","--active"],"stdout":"applied"}` 却回 `exit status 1`。

后果：**LuCI 会把成功操作显示成失败**。且两次都见 `bin: lua` → **OpenWrt 上仍走 Lua 执行器**（O1-③/O3 的"退役 Lua"证据再加一条）。
