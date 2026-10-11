-- mynet/proxy.lua — Proxy 分流模块管理
-- 对齐 client proxy 插件：start/stop/status/diagnose
-- 通过调用 shell 脚本实现，提供结构化 JSON 接口给 LuCI

local M    = {}
local util = require("luci.model.mynet.util")

-- ─────────────────────────────────────────────────────────────
-- 路径常量
-- ─────────────────────────────────────────────────────────────

local PROXY_CONF_DIR   = util.CONF_DIR .. "/proxy"
local PROXY_ROLE_CONF  = PROXY_CONF_DIR .. "/proxy_role.conf"
local PROXY_STATE_FILE = util.MYNET_HOME .. "/var/proxy_state.json"

-- 参数校验常量（controller/model 共用，避免重复定义）
local VALID_MODES    = { client = true, server = true, both = true }
local VALID_REGIONS  = { domestic = true, international = true }
local VALID_POLICIES = { whitelist = true, blacklist = true }
local VALID_DNS      = { none = true, redirect = true, resolv = true, split = true }

-- 非国内 DNS 服务器列表（始终通过 proxy_peer 路由）
M.FOREIGN_DNS_SERVERS = {
    "8.8.8.8",      -- Google DNS
    "8.8.4.4",      -- Google DNS secondary
    "1.1.1.1",      -- Cloudflare DNS
    "1.0.0.1",      -- Cloudflare DNS secondary
    "9.9.9.9",      -- Quad9 DNS
    "208.67.222.222", -- OpenDNS
    "208.67.220.220", -- OpenDNS secondary
}

-- 国内 DNS 服务器（split 模式默认）
M.DOMESTIC_DNS_SERVERS = { "223.5.5.5", "119.29.29.29" }

-- ─────────────────────────────────────────────────────────────
-- 配置读写
-- ─────────────────────────────────────────────────────────────

-- 校验 proxy 参数（mode/region/proxy_policy/dns_mode）
function M.validate_params(opts)
    if opts.mode and not VALID_MODES[opts.mode] then
        return nil, "invalid mode: " .. tostring(opts.mode)
    end
    if opts.region and not VALID_REGIONS[opts.region] then
        return nil, "invalid region: " .. tostring(opts.region)
    end
    if opts.proxy_policy and not VALID_POLICIES[opts.proxy_policy] then
        return nil, "invalid proxy_policy: " .. tostring(opts.proxy_policy)
    end
    if opts.dns_mode and not VALID_DNS[opts.dns_mode] then
        return nil, "invalid dns_mode: " .. tostring(opts.dns_mode)
    end
    return true
end

-- 读取 proxy_role.conf (bash KEY=VALUE 格式)
function M.load_config()
    local defaults = {
        proxy_enabled = false,
        proxy_mode    = "client",
        node_region   = "domestic",
        proxy_policy  = "whitelist",
        dns_mode      = "none",
        dns_server    = "",
        proxy_peers   = "",
    }
    local result = util.parse_bash_conf(PROXY_ROLE_CONF, { lower_keys = true })
    if not result then return defaults end
    -- 向下兼容：旧版 non_domestic → domestic + blacklist
    local region = result.node_region or "domestic"
    local policy = result.proxy_policy or "whitelist"
    if region == "non_domestic" then
        region = "domestic"
        policy = "blacklist"
    end
    return {
        proxy_enabled        = (result.proxy_enabled == "1" or result.proxy_enabled == "true"),
        proxy_mode           = result.proxy_mode  or "client",
        node_region          = region,
        proxy_policy         = policy,
        dns_mode             = result.dns_mode    or "none",
        dns_server           = result.dns_server  or "",
        dns_domestic_server  = result.dns_domestic_server or "",
        proxy_peers          = result.proxy_peers or "",
    }
end

-- 合并更新配置（load → merge → save，避免调用方重复 load+save）

-- ─────────────────────────────────────────────────────────────
-- 状态查询（解析 JSON 输出或 fallback 到进程检测）
-- ─────────────────────────────────────────────────────────────

function M.get_status()
    -- 注意：分流已归 Go（`mynet proxy apply`），本函数只是**读探测**（供 LuCI 渲染）。
    -- 权威状态在 localapi `GET /api/v1/plugin/proxy`（effective/local/cloud），
    -- 页面走桥取；这里保留系统探测作为兜底。

    -- Fallback: 通过系统状态检测
    -- 同时检查 ipset (fw3 / iptables 设备) 和 nftables (fw4 设备)
    local running = false
    local ipset_count = 0
    local nft_count = 0
    local route_table_id = nil

    -- 检查 ipset（fw3 + iptables 设备）
    local ipset_out = util.trim(util.exec(
        "ipset list mynet_proxy 2>/dev/null | grep 'Number of entries' | awk '{print $NF}'") or "")
    if ipset_out ~= "" then
        ipset_count = tonumber(ipset_out) or 0
        if ipset_count > 0 then running = true end
    end

    -- 检测 nftables set（自建表 `ip mynet_proxy`，集合同名）
    local nft_has = util.trim(util.exec(
        "nft list set ip mynet_proxy mynet_proxy 2>/dev/null | grep -c 'elements'") or "")
    if tonumber(nft_has) and tonumber(nft_has) > 0 then
        running = true
        local cnt_out = util.trim(util.exec(
            "nft list set ip mynet_proxy mynet_proxy 2>/dev/null | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+' | wc -l") or "")
        nft_count = tonumber(cnt_out) or 0
    end

    -- 获取路由表 ID
    local rt_out = util.trim(util.exec(
        "grep -E '^[[:space:]]*[0-9]+[[:space:]]+mynet_proxy' /etc/iproute2/rt_tables 2>/dev/null | awk '{print $1}'") or "")
    if rt_out ~= "" then route_table_id = tonumber(rt_out) end

    -- 获取配置
    local cfg = M.load_config()

    -- 检查 ip rule 是否有 fwmark 规则
    local has_rule = false
    if route_table_id then
        local rule_out = util.trim(util.exec(
            "ip rule list 2>/dev/null | grep 'lookup mynet_proxy'") or "")
        has_rule = rule_out ~= ""
    end

    -- 计算 uptime（从 state file）
    local uptime_sec = 0
    local state_data = util.load_json_file(PROXY_STATE_FILE)
    if state_data and state_data.start_ts then
        uptime_sec = os.time() - (state_data.start_ts or os.time())
        if uptime_sec < 0 then uptime_sec = 0 end
    end

    -- peer 数量
    local peer_count = 0
    if cfg.proxy_peers ~= "" then
        for _ in cfg.proxy_peers:gmatch("[^,]+") do
            peer_count = peer_count + 1
        end
    end

    -- proxy_route.conf 中的 CIDR 条目数（已配置的规则数）
    local route_conf_count = 0
    local route_conf_path = PROXY_CONF_DIR .. "/proxy_route.conf"
    if util.file_exists(route_conf_path) then
        local cnt_out = util.trim(util.exec(
            "grep -cv '^#\\|^$' " .. util.shell_escape(route_conf_path) .. " 2>/dev/null") or "")
        route_conf_count = tonumber(cnt_out) or 0
    end

    -- route 注入状态（从 route.conf marker 推断，而非硬编码 false）
    local inj_status = M.route_inject_status() or {}

    -- 国外 DNS 是否已被引入 GNB 隧道（检测首个服务器作为样本）
    local foreign_dns_routed = false
    if #M.FOREIGN_DNS_SERVERS > 0 then
        local sample = M.FOREIGN_DNS_SERVERS[1]
        local rg = util.exec("ip route get " .. sample .. " 2>/dev/null | head -1") or ""
        local cfg_m_local = require("luci.model.mynet.config")
        local iface = cfg_m_local.get_vpn_interface()
        if iface and rg:find("dev " .. iface, 1, true) then
            foreign_dns_routed = true
        end
    end

    -- 匹配模式（由 proxy_policy 决定，向下兼容旧 non_domestic）
    local match_mode = (cfg.proxy_policy == "blacklist") and "inverted" or "normal"

    return {
        running         = running,
        mode            = cfg.proxy_mode,
        region          = cfg.node_region,
        proxy_policy    = cfg.proxy_policy or "whitelist",
        match_mode      = match_mode,
        dns_mode        = cfg.dns_mode,
        layers          = {
            route_inject       = inj_status.injected and true or false,
            policy_routing     = running,
            dns_intercept      = cfg.dns_mode ~= "none" and running,
            foreign_dns_routed = foreign_dns_routed,
        },
        stats           = {
            ipset_count      = ipset_count,
            nft_count        = nft_count,
            route_conf_count = route_conf_count,
            route_table_id   = route_table_id,
            peer_count       = peer_count,
            uptime_seconds   = uptime_sec,
            has_rule         = has_rule,
        },
    }
end

-- ─────────────────────────────────────────────────────────────
-- 诊断指定 IP 的路由路径
-- ─────────────────────────────────────────────────────────────

function M.diagnose_ip(ip)
    if not ip or not ip:match("^%d+%.%d+%.%d+%.%d+$") then
        return nil, "invalid IPv4 address"
    end

    local result = { ip = ip, checks = {} }

    -- 1. ip route get
    local route_out = util.trim(util.exec(
        "ip route get " .. util.shell_escape(ip) .. " 2>/dev/null") or "")
    result.checks[#result.checks + 1] = {
        name = "ip_route_get",
        output = route_out,
    }

    -- 2. ipset test
    local ipset_out, ipset_code = util.exec_status(
        "ipset test mynet_proxy " .. util.shell_escape(ip) .. " 2>&1")
    result.checks[#result.checks + 1] = {
        name    = "ipset_test",
        matched = ipset_code == 0,
        output  = util.trim(ipset_out or ""),
    }

    -- 3. nftables lookup
    local nft_out = util.trim(util.exec(
        "nft get element inet mynet_proxy mynet_proxy '{ "
        .. ip .. " }' 2>/dev/null") or "")
    result.checks[#result.checks + 1] = {
        name    = "nft_lookup",
        matched = nft_out ~= "",
        output  = nft_out,
    }

    -- 4. traceroute (quick, 3 hops max)
    local trace = util.trim(util.exec(
        "traceroute -n -m 3 -w 1 " .. util.shell_escape(ip) .. " 2>/dev/null") or "")
    result.checks[#result.checks + 1] = {
        name   = "traceroute",
        output = trace,
    }

    return result, nil
end

-- ─────────────────────────────────────────────────────────────
-- Route Inject — 向 GNB route.conf 注入 proxy 路由
--
-- GNB 数据层需要 route.conf 声明才会转发对应网段的流量，缺失则丢包。
-- 注入使用 GNB pipe 格式: peer_nid|network|netmask
-- OS 层路由由 route_policy.sh 独立路由表 + fwmark 处理，此处不触发 sync_top_route_conf
--
-- 两段注入结构（mode=server/both 时）：
--   #----proxy-server start/end----  : 自身 nodeId 路由，告知 GNB 放行入站转发包
--   #----proxy start/end----         : peer nodeId 路由，本机出站流量走 proxy peer
--
-- GNB 路由优先级规则：
--   - 不同前缀长度：更精确（更长）的优先（/16 > /8）
--   - 相同前缀长度：后面的条目生效（last-match）
--
-- 172.x.x.x 冲突解决：
--   proxy-server 段为绕开 172.16.0.0/12 私有段，必须用 /16 粒度（240 条）
--   proxy client 段同样用 /16，且追加在后 → 相同前缀 last-match → peer 路由生效
--   其余公网段用 /8，两段相同前缀，proxy client 在后 → peer 路由生效
-- ─────────────────────────────────────────────────────────────

-- Marker（与 scripts/proxy/hooks/stop.sh 统一）
M.INJECT_MARKER_BEGIN        = "#----proxy start----"
M.INJECT_MARKER_END          = "#----proxy end----"
local INJECT_SERVER_MARKER_BEGIN = "#----proxy-server start----"
local INJECT_SERVER_MARKER_END   = "#----proxy-server end----"

-- 获取 GNB route.conf 路径（driver/gnb/conf/{nid}/route.conf）
local function get_route_conf_path()
    local cfg_m = require("luci.model.mynet.config")
    local node_id = cfg_m.get_node_id()
    if not node_id then return nil, "node_id not configured" end
    local nid_str = util.int_str(node_id)
    local conf_root = cfg_m.get_gnb_conf_root()
    return conf_root .. "/" .. nid_str .. "/route.conf", nid_str
end

-- 从文件内容中移除两个 proxy marker 段（含 marker 行本身）
-- 判断是否为 proxy marker 开始行，兼容新旧格式：
--   新格式: #----proxy start----  /  #----proxy-server start----
--   旧格式: #---------proxy start {nodeId}--------
local function is_proxy_marker_begin(line)
    if line:sub(1,1) ~= "#" then return false end
    return line:find(M.INJECT_MARKER_BEGIN, 1, true)
        or line:find(INJECT_SERVER_MARKER_BEGIN, 1, true)
        or line:find("proxy start", 1, true)
end
local function is_proxy_marker_end(line)
    if line:sub(1,1) ~= "#" then return false end
    return line:find(M.INJECT_MARKER_END, 1, true)
        or line:find(INJECT_SERVER_MARKER_END, 1, true)
        or line:find("proxy end", 1, true)
end

local function strip_marker_section(content)
    if not content then return content end
    -- 快速判断是否需要处理
    if not content:find("proxy start", 1, true) then return content end
    local result = {}
    local skipping = false
    for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        if is_proxy_marker_begin(line) then
            skipping = true
        elseif is_proxy_marker_end(line) then
            skipping = false
        elseif not skipping then
            result[#result + 1] = line
        end
    end
    while #result > 0 and result[#result] == "" do
        result[#result] = nil
    end
    return table.concat(result, "\n") .. "\n"
end

-- 导出给 node.lua 使用：生成系统路由前剔除 proxy 注入段
M.strip_route_injections = strip_marker_section

-- 收集代理出口的公网 IP（逗号分隔），供 exclude_ips 使用。
-- 唯一来源是本节点 address.conf 的 n|/p| 行（host 即对端公网 endpoint）。
-- PROXY_GATEWAYS 里那些是 overlay IP，是隧道路由的**目标**而不是 underlay，
-- 剔了反而断链，所以本函数不收它们、也不接收网关参数。
--
-- ⚠️ 已知缺口：index 服务器（idx.mynet.club）的公网 IP 不在 address.conf 里，
--    因此没被 exclude。原处是一个空 for 循环占位（看着像漏写，其实是没做），
--    已删除并在此显式记账。真要补，得在启动时解析域名并缓存 IP，属新工作。
function M.collect_proxy_public_ips()
    local ips = {}
    local seen = {}
    local function add(ip)
        ip = util.trim(ip or "")
        if ip ~= "" and not seen[ip] and ip:match("^%d+%.%d+%.%d+%.%d+$") then
            seen[ip] = true
            ips[#ips + 1] = ip
        end
    end
    -- address.conf：n|<id>|<host>|<port> 的 host 即公网 endpoint
    local cfg_m = require("luci.model.mynet.config")
    local nid = cfg_m.get_node_id()
    if nid then
        local ac = util.read_file(string.format("%s/%s/address.conf", cfg_m.get_gnb_conf_root(), util.int_str(nid))) or ""
        for line in ac:gmatch("[^\n]+") do
            local role, _id, host = line:match("^([%w])|([^|]+)|([^|]+)|")
            if role == "n" or role == "p" then
                add(host)
            end
        end
    end
    return table.concat(ips, ",")
end

-- 注入 proxy 路由到 GNB route.conf
-- 【已收窄】旧 fresh 会灌几百条 /8+/16 进 route.conf，挤爆 gnb 节点表
-- （实测 188/658289 不进 uuid_node_map）。现在代理走 L6：nft set + fwmark
-- + mynet_proxy 表（nexthop=出口 overlay IP），gnb route.conf 只保留
-- overlay /32 与真实对等网段。此函数只做清理，不再回灌。
function M.route_inject()
    local route_conf, nid_str = get_route_conf_path()
    if not route_conf then return nil, nid_str end

    if not util.file_exists(route_conf) then
        return nil, "route.conf not found: " .. route_conf
    end

    local orig = util.read_file(route_conf) or ""
    local clean = strip_marker_section(orig)
    if clean ~= orig then
        util.write_file(route_conf, clean)
        util.log_info("route_inject: stripped legacy proxy routes from route.conf (L6 handles split)")
    end
    return { injected = 0, stripped = (clean ~= orig) }
end

-- 从 GNB route.conf 移除 proxy 注入段
function M.route_restore()
    local route_conf = get_route_conf_path()
    if not route_conf then return nil, "node_id not configured" end

    local content = util.read_file(route_conf) or ""
    if not content:find(M.INJECT_MARKER_BEGIN, 1, true) then
        return true, "nothing to restore"
    end

    local clean = strip_marker_section(content)
    util.write_file(route_conf, clean)
    util.log_info("route_restore: removed proxy marker section")
    return true, "removed injected section"
end

-- 注入状态查询
function M.route_inject_status()
    local route_conf = get_route_conf_path()
    if not route_conf then return { injected = false, error = "node_id not configured" } end
    if not util.file_exists(route_conf) then
        return { injected = false, error = "route.conf not found" }
    end

    local content = util.read_file(route_conf) or ""
    local has_marker = content:find(M.INJECT_MARKER_BEGIN, 1, true) ~= nil
    local count = 0
    if has_marker then
        for line in content:gmatch("[^\n]+") do
            -- 匹配三种 CIDR：/8 (255.0.0.0)、/16 (255.255.0.0)、/24 (255.255.255.0)
            if line:match("^%d+|%d+%.0%.0%.0|255%.0%.0%.0$")
                or line:match("^%d+|%d+%.%d+%.0%.0|255%.255%.0%.0$")
                or line:match("^%d+|%d+%.%d+%.%d+%.0|255%.255%.255%.0$") then
                count = count + 1
            end
        end
    end

    return {
        injected    = has_marker,
        route_count = count,
    }
end

-- ─────────────────────────────────────────────────────────────
-- 网络检测（从 controller 移入 model，统一业务逻辑层）
-- ─────────────────────────────────────────────────────────────

function M.net_detect(dtype)
    local cmd
    if dtype == "domestic" then
        cmd = "curl -s --connect-timeout 5 --max-time 10 'https://myip.ipip.net' 2>/dev/null"
            .. " || curl -s --connect-timeout 5 --max-time 10 'https://ip.cn/api/index?type=0' 2>/dev/null"
    elseif dtype == "proxy" then
        cmd = "curl -s --connect-timeout 8 --max-time 15 'https://api.ipify.org?format=json' 2>/dev/null"
            .. " || curl -s --connect-timeout 8 --max-time 15 'https://ifconfig.me/ip' 2>/dev/null"
    else
        return nil, "invalid type: " .. tostring(dtype)
    end
    local out = util.trim(util.exec(cmd) or "")
    if out ~= "" then
        return { ip = out:match("%d+%.%d+%.%d+%.%d+") or out, raw = out }
    end
    return nil, dtype .. " IP detection failed"
end

function M.net_check(host)
    if not host or host == "" or not host:match("^[%w%.%-]+$") then
        return nil, "invalid host"
    end
    local cmd = string.format(
        "curl -s -o /dev/null -w '%%{http_code} %%{time_total} %%{remote_ip}' "
        .. "--connect-timeout 8 --max-time 15 'https://%s/' 2>/dev/null",
        util.shell_escape(host):gsub("'", ""))
    local out = util.trim(util.exec(cmd) or "")
    local code, time_s, ip = out:match("^(%d+)%s+([%d%.]+)%s+([%d%.]+)")
    if code then
        return {
            host      = host,
            reachable = tonumber(code) > 0 and tonumber(code) < 500,
            http_code = tonumber(code),
            time_ms   = math.floor(tonumber(time_s) * 1000),
            ip        = ip,
        }
    end
    return {
        host      = host,
        reachable = false,
        error     = out ~= "" and out or "connection failed",
    }
end

return M
