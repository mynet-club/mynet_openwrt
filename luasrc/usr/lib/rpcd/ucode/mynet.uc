// mynet — rpcd ucode 桥（O2）：LuCI → 本机 mynetd localapi（127.0.0.1:8096）
//
// 约束（O2）：
//   * 只走**固定方法表**；不接受自由 path / 任意 argv（argv 逐动作写死）
//   * 不返回私钥；**不裸放 system.json**（该端点不映射）
//   * 登录只走既有端点；桥不新增认证路径
//   * 请求体走临时文件 + `curl --data @file`，不做 shell 拼接
//   * daemon 不在 / 超时 / 会话被拒 / 互斥冲突 可区分
{{
	const fs = require("fs");

	const API = "http://127.0.0.1:8096";
	const BODY_FILE = "/tmp/.mynet-bridge.body";

	// 固定方法表：ubus 方法 -> { m: get|post, p: path, q: 数字查询白名单, body: 字段白名单, argv: 固定 argv }
	const TABLE = {
		status:           { m: "get",  p: "/api/v1/status" },
		"node-status":    { m: "get",  p: "/api/v1/node-status" },
		nodes:            { m: "get",  p: "/api/v1/nodes" },
		identity:         { m: "get",  p: "/api/v1/config/identity" },
		runtime:          { m: "get",  p: "/api/v1/config/runtime" },
		tenants:          { m: "get",  p: "/api/v1/config/tenants" },
		"wizard-state":   { m: "get",  p: "/api/v1/wizard/state" },
		metrics:          { m: "get",  p: "/api/v1/metrics" },
		logs:             { m: "get",  p: "/api/v1/logs", q: [ "lines" ] },
		"proxy-status":   { m: "get",  p: "/api/v1/plugin/proxy" },
		connect:          { m: "post", p: "/api/v1/config/connect" },
		sync:             { m: "post", p: "/api/v1/config/apply", body: [ "active", "auto" ] },
		"keys-sync":      { m: "post", p: "/api/v1/config/keys", body: [ "action", "pub_hex" ] },
		"switch-node":    { m: "post", p: "/api/v1/nodes/switch", body: [ "node_id" ] },
		"proxy-set":      { m: "post", p: "/api/v1/plugin/proxy", body: [ "enabled" ] },
		service:          { m: "post", p: "/api/v1/command", argv: {
			start:   [ "mynet", "service", "start",   "gnb" ],
			stop:    [ "mynet", "service", "stop",    "gnb" ],
			restart: [ "mynet", "service", "restart", "gnb" ],
			status:  [ "mynet", "service", "status",  "gnb" ],
		} }
	};

	function fail(what, extra) {
		let r = { success: false, error: what };
		if (extra != null) r.detail = extra;
		return r;
	}

	// 只放行白名单字段；其余丢弃（绝不把 req 原样透传）
	function pick(req, keys) {
		let out = {};
		if (!req || !keys) return out;
		for (let k in keys) {
			if (req[keys[k]] != null) out[keys[k]] = req[keys[k]];
		}
		return out;
	}

	function call(name, req) {
		let e = TABLE[name];
		if (!e) return fail("unknown-method", name);

		let url = API + e.p;

		// 数字查询白名单（如 logs.lines）
		if (e.q) {
			let qs = [];
			for (let i = 0; i < length(e.q); i++) {
				let k = e.q[i];
				if (req && req[k] != null) {
					if (!match(req[k], /^[0-9]{1,4}$/))
						return fail("bad-param", k);
					qs = push(qs, k + "=" + req[k]);
				}
			}
			if (length(qs)) url += "?" + join("=", qs);
		}

		let method = e.m == "post" ? "post" : "get";
		let cmd;

		if (method == "post") {
			let data = {};
			if (e.argv) {
				let act = req ? req.action : null;
				if (act == null) act = "status";
				let argv = e.argv[act];
				if (argv == null) return fail("bad-param", "action");
				data = { argv: argv };
			} else if (e.body) {
				data = pick(req, e.body);
			}
			fs.writefile(BODY_FILE, sprintf("%J", data));
			cmd = "curl -sS -m 10 -X POST -H 'Content-Type: application/json' --data @" + BODY_FILE + " " + url;
		} else {
			cmd = "curl -sS -m 10 " + url;
		}

		let out, code = "http";
		try {
			let p = fs.popen(cmd + " -w '\\n%{http_code}'");
			out = p ? p.read("all") : "";
			if (p) p.close();
		} catch (e2) {
			return fail("daemon-unavailable");
		}
		if (out == null || out == "") return fail("daemon-unavailable");

		let idx = rindex(out, "\n");
		if (idx < 0) return fail("timeout");
		code = substr(out, idx + 1);
		out = substr(out, 0, idx);
		if (code == "000") return fail("timeout");
		if (code == "409") return fail("operation-in-progress");
		if (code == "401" || code == "403") return fail("session-rejected", code);
		if (substr(code, 0, 1) != "2") return fail("upstream", code);

		try { return { success: true, data: json(out) }; }
		catch (e3) { return { success: true, data: out }; }
	}

	return {
		status:            { args: {}, call: function(req) { return call("status", req); } },
		"node-status":     { args: {}, call: function(req) { return call("node-status", req); } },
		nodes:             { args: {}, call: function(req) { return call("nodes", req); } },
		identity:          { args: {}, call: function(req) { return call("identity", req); } },
		runtime:           { args: {}, call: function(req) { return call("runtime", req); } },
		tenants:           { args: {}, call: function(req) { return call("tenants", req); } },
		"wizard-state":    { args: {}, call: function(req) { return call("wizard-state", req); } },
		metrics:           { args: {}, call: function(req) { return call("metrics", req); } },
		logs:              { args: { lines: 0 }, call: function(req) { return call("logs", req); } },
		"proxy-status":    { args: {}, call: function(req) { return call("proxy-status", req); } },
		connect:           { args: {}, call: function(req) { return call("connect", req); } },
		sync:              { args: { active: false, auto: false }, call: function(req) { return call("sync", req); } },
		"keys-sync":       { args: { action: "", pub_hex: "" }, call: function(req) { return call("keys-sync", req); } },
		"switch-node":     { args: { node_id: "" }, call: function(req) { return call("switch-node", req); } },
		"proxy-set":       { args: { enabled: false }, call: function(req) { return call("proxy-set", req); } },
		service:           { args: { action: "" }, call: function(req) { return call("service", req); } }
	};
}}
