-- mynet/bridge.lua — LuCI → 本机管理桥（O5）
--
-- 页面**唯一**的本地状态/操作入口：LuCI Lua → `ubus call mynet.<method>` →
-- rpcd ucode 桥 → 本机 mynetd localapi（127.0.0.1:8096）。
-- 页面不再各自直连 `rc.mynet` / `config.lua` / `node.lua` 做系统写入
-- （O5 禁「直接 auth/node/proxy 系统写入」）。
--
-- 方法表**冻结**，与两处必须逐项一致：
--   1. rpcd 桥 `/usr/share/rpcd/ucode/mynet.uc` 的 `methods`；
--   2. ubus ACL `.../acl.d/luci-app-mynet.json` 的读(10)/写(6)。
-- 门禁 `scripts/tools/check_bridge_acl.sh` 断言三方不漂移。
-- 映射与安全边界见 `docs/O2-BRIDGE-METHOD-MAP.md`。

local M = {}
local util = require("luci.model.mynet.util")

M.METHODS = {
    -- 读（ACL read）
    "status", "node-status", "nodes", "identity", "runtime",
    "tenants", "wizard-state", "metrics", "proxy-status", "logs",
    -- 写（ACL write）
    "connect", "apply", "keys", "active", "prepare",
    "switch-node", "proxy-set", "service",
}

local METHOD_SET = {}
for _, m in ipairs(M.METHODS) do METHOD_SET[m] = true end

-- call(method, args) -> (result_table, nil) | (nil, err)
-- result_table 形如 { success = bool, data = {...} }（localapi 原信封，桥已透传）。
-- args 为可选 table；未知方法在此**先于** ubus 拒绝（与桥同口径 fail-closed）。
function M.call(method, args)
    if not METHOD_SET[method] then
        return nil, "unknown-method: " .. tostring(method)
    end

    local cmd = "ubus call mynet " .. util.shell_escape(method)
    if args and next(args) ~= nil then
        cmd = cmd .. " " .. util.shell_escape(util.json_encode(args))
    end

    local out, code = util.exec_status(cmd)
    out = util.trim(out or "")
    if code ~= 0 then
        return nil, (out ~= "" and out) or ("bridge exit " .. tostring(code))
    end
    if out == "" then
        return nil, "empty response"
    end

    local data = util.json_decode(out)
    if not data then
        return nil, "bad json: " .. out:sub(1, 120)
    end
    return data, nil
end

-- available() 桥是否可用（daemon 在位）。供页面决定「未绑定/离线」显示。
function M.available()
    local ok = M.call("status")
    return ok ~= nil
end

-- ── 读（页面状态）───────────────────────────────────────────────
function M.status()       return M.call("status") end
function M.node_status()  return M.call("node-status") end
function M.nodes()        return M.call("nodes") end
function M.identity()     return M.call("identity") end
function M.runtime()      return M.call("runtime") end
function M.tenants()      return M.call("tenants") end
function M.wizard_state() return M.call("wizard-state") end
function M.metrics()      return M.call("metrics") end
function M.proxy_status() return M.call("proxy-status") end
-- logs：lines 需为**数字字符串**（.uc 侧用 /^[0-9]{1,4}$/ 校验，传 number 会被拒）
function M.logs(lines)    return M.call("logs", lines and { lines = tostring(lines) } or nil) end

-- ── 写（页面操作）───────────────────────────────────────────────
-- fields 为 table；逐字段白名单由 .uc 侧限定（与 localapi handler 字段对齐）。
function M.connect()            return M.call("connect") end
function M.apply(start)         return M.call("apply", { start = start }) end
function M.keys(fields)         return M.call("keys", fields) end
function M.active(fields)       return M.call("active", fields) end
function M.prepare()            return M.call("prepare") end
function M.switch_node(node_id) return M.call("switch-node", { node_id = node_id }) end
-- policy 经 .uc 的 jsonArg 传：这里编码成 JSON 字符串（rpcd arg 恒为 String）
function M.proxy_set(policy)    return M.call("proxy-set", { policy = util.json_encode(policy) }) end

-- service(op) op ∈ {start,stop,reload,restart}（执行器白名单，见 O2 映射表）
function M.service(op)          return M.call("service", { action = op }) end

return M
