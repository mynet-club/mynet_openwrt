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
