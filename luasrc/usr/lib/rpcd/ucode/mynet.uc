// mynet — rpcd ucode 桥（O2）：LuCI → 本机 mynetd localapi（127.0.0.1:8096）
//
// 约束：只走固定映射；argv 逐动作写死；不返回私钥；不映射 system.json；
//       shell 传参一律 shellquote；错误可区分。
// 方言参照设备自带的 rpcd 插件（luci.wireguard）：标准脚本 + import + 顶层 return {对象名:methods}。

'use strict';

import { popen } from 'fs';

const API = 'http://127.0.0.1:8096';

function shellquote(s) {
	return `'${replace(s ?? '', "'", "'\\''")}'`;
}

function run(cmd) {
	const p = popen(cmd);
	const out = p ? trim(p.read('all') ?? '') : '';
	if (p) p.close();
	return out;
}

// 固定方法表：只读映射；argv 逐动作写死（不接受任意 argv）
//
// 写侧 body 白名单与 localapi handler 的**实际字段**逐一对齐（曾写成
// `active/auto`、`action/pub_hex`、`enabled` —— 与 handler 的
// `start` / `generate·private_hex·public_hex` / `policy` 不符，会 400）。
const TABLE = {
	status:         { m: 'get',  p: '/api/v1/status' },
	'node-status':  { m: 'get',  p: '/api/v1/node-status' },
	nodes:          { m: 'get',  p: '/api/v1/nodes' },
	identity:       { m: 'get',  p: '/api/v1/config/identity' },
	runtime:        { m: 'get',  p: '/api/v1/config/runtime' },
	tenants:        { m: 'get',  p: '/api/v1/config/tenants' },
	'wizard-state': { m: 'get',  p: '/api/v1/wizard/state' },
	metrics:        { m: 'get',  p: '/api/v1/metrics' },
	'proxy-status': { m: 'get',  p: '/api/v1/plugin/proxy' },
	logs:           { m: 'get',  p: '/api/v1/logs', lines: true },
	// 写
	connect:        { m: 'post', p: '/api/v1/config/connect' },
	apply:          { m: 'post', p: '/api/v1/config/apply',  body: [ 'start' ], boolBody: [ 'start' ] },
	keys:           { m: 'post', p: '/api/v1/config/keys',   body: [ 'generate', 'private_hex', 'public_hex', 'node_id', 'vpn_type' ], boolBody: [ 'generate' ] },
	active:         { m: 'post', p: '/api/v1/config/active', body: [ 'tenant', 'node', 'setup_only', 'vpn_type' ], boolBody: [ 'setup_only' ] },
	prepare:        { m: 'post', p: '/api/v1/config/prepare' },
	'switch-node':  { m: 'post', p: '/api/v1/nodes/switch',  body: [ 'node_id' ] },
	// policy 是**嵌套对象**：rpcd 把所有 arg 当 String，直接传对象会 INVALID_ARGUMENT，
	// 故经 `jsonArg` 收 JSON 字符串再解回对象（客户端负责 json 编码）。
	'proxy-set':    { m: 'post', p: '/api/v1/plugin/proxy',  body: [ 'policy' ], jsonArg: 'policy' },
	// route-apply：固定 argv 的 OS 路由/防火墙应用（跨平台，Go 的 apply --auto）
	'route-apply':  { m: 'post', p: '/api/v1/command', fixedArgv: [ 'apply', '--auto' ] },
	// service：action 以**执行器实现**为准（OpenWrt 上 mynetd 走 Lua，
	// 白名单 = start|stop|reload|restart；**不含 status**，状态请用 status/runtime）
	service:        { m: 'post', p: '/api/v1/command', argv: {
		start:   [ 'service', 'start',   'gnb' ],
		stop:    [ 'service', 'stop',    'gnb' ],
		reload:  [ 'service', 'reload',  'gnb' ],
		restart: [ 'service', 'restart', 'gnb' ]
	} }
};

function call(name, req) {
	const e = TABLE[name];
	if (!e)
		return { success: false, error: 'unknown-method', detail: name };

	const args = req?.args ?? {};
	let url = API + e.p;

	if (e.lines && args.lines != null) {
		if (!match(args.lines, /^[0-9]{1,4}$/))
			return { success: false, error: 'bad-param', detail: 'lines' };
		url += '?lines=' + args.lines;
	}

	let cmd = `curl -sS -m 10 -w '\\n%{http_code}' `;

	if (e.m == 'post') {
		let data;

		if (e.fixedArgv) {
			// 固定 argv（不接收外部 argv）：整条动作写死，防任意命令
			data = { argv: e.fixedArgv };
		}
		else if (e.argv) {
			const act = args.action ?? 'status';
			if (e.argv[act] == null)
				return { success: false, error: 'bad-param', detail: 'action' };
			data = { argv: e.argv[act] };
		}
		else {
			data = {};
			// ⚠️ 用**下标**遍历 e.body：ucode 的 `for (k in array)` 取的是**元素值**
			// 而非下标，写成 `e.body[k]` 会取空（实测 body 分支因此静默丢参）。
			const names = e.body ?? [];
			for (let bi = 0; bi < length(names); bi++) {
				const fld = names[bi];
				if (args[fld] == null)
					continue;
				let v = args[fld];
				// jsonArg：该字段以 JSON **字符串**传入（见 TABLE 注释），解回对象/数组。
				// ⚠️ 不用 `typeof`/`type` 做类型判断：**rpcd 的 ucode 宿主里它们不可用**
				// （实测一调就抛、ubus 只回 "Unknown error"）。直接 try-parse 最稳。
				if (e.jsonArg == fld) {
					let d2 = null;
					try { d2 = json(v); } catch (je) { d2 = null; }
					if (d2 == null)
						return { success: false, error: 'bad-param', detail: fld };
					v = d2;
				}
				data[fld] = v;
			}
			// boolBody：这些字段 rpcd 只能给字符串，这里转回**真布尔**（Go 侧是 bool，
			// 收 "true"/"false" 字符串会 unmarshal 失败）。
			const bools = e.boolBody ?? [];
			for (let b2 = 0; b2 < length(bools); b2++) {
				const bf = bools[b2];
				if (data[bf] != null)
					data[bf] = (data[bf] == 'true' || data[bf] == '1');
			}
		}

		cmd += `-X POST -H 'Content-Type: application/json' --data ${shellquote(sprintf('%J', data))} `;
	}

	const out = run(cmd + shellquote(url));
	const idx = rindex(out, '\n');
	if (idx < 0)
		return { success: false, error: 'daemon-unavailable' };

	const code = trim(substr(out, idx + 1));
	const body = substr(out, 0, idx);

	if (code == '000')
		return { success: false, error: 'timeout' };
	if (code == '409')
		return { success: false, error: 'operation-in-progress', status: 409 };
	if (code == '401' || code == '403')
		return { success: false, error: 'session-rejected', status: +code };
	if (substr(code, 0, 1) != '2')
		return { success: false, error: 'upstream', status: +code, detail: substr(body, 0, 200) };

	// localapi 自身已返回 {success,data} 信封 → 原样透传，避免 data.data 双层
	try { return json(body); }
	catch (e2) { return { success: true, raw: body }; }
}

const methods = {
	status:            { call: (req) => call('status', req) },
	'node-status':     { call: (req) => call('node-status', req) },
	nodes:             { call: (req) => call('nodes', req) },
	identity:          { call: (req) => call('identity', req) },
	runtime:           { call: (req) => call('runtime', req) },
	tenants:           { call: (req) => call('tenants', req) },
	'wizard-state':    { call: (req) => call('wizard-state', req) },
	metrics:           { call: (req) => call('metrics', req) },
	'proxy-status':    { call: (req) => call('proxy-status', req) },
	logs:              { args: { lines: 'lines' }, call: (req) => call('logs', req) },
	connect:           { call: (req) => call('connect', req) },
	'route-apply':     { call: (req) => call('route-apply', req) },
	apply:             { args: { start: 'start' }, call: (req) => call('apply', req) },
	keys:              { args: { generate: 'generate', private_hex: 'private_hex', public_hex: 'public_hex', node_id: 'node_id', vpn_type: 'vpn_type' }, call: (req) => call('keys', req) },
	active:            { args: { tenant: 'tenant', node: 'node', setup_only: 'setup_only', vpn_type: 'vpn_type' }, call: (req) => call('active', req) },
	prepare:           { call: (req) => call('prepare', req) },
	'switch-node':     { args: { node_id: 'node_id' }, call: (req) => call('switch-node', req) },
	'proxy-set':       { args: { policy: 'policy' }, call: (req) => call('proxy-set', req) },
	service:           { args: { action: 'action' }, call: (req) => call('service', req) }
};

return { mynet: methods };
