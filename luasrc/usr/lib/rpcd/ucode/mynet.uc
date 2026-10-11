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
	apply:          { m: 'post', p: '/api/v1/config/apply',  body: [ 'start' ] },
	keys:           { m: 'post', p: '/api/v1/config/keys',   body: [ 'generate', 'private_hex', 'public_hex', 'node_id', 'vpn_type' ] },
	active:         { m: 'post', p: '/api/v1/config/active', body: [ 'tenant', 'node', 'setup_only', 'vpn_type' ] },
	prepare:        { m: 'post', p: '/api/v1/config/prepare' },
	'switch-node':  { m: 'post', p: '/api/v1/nodes/switch',  body: [ 'node_id' ] },
	'proxy-set':    { m: 'post', p: '/api/v1/plugin/proxy',  body: [ 'policy' ] },
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

		if (e.argv) {
			const act = args.action ?? 'status';
			if (e.argv[act] == null)
				return { success: false, error: 'bad-param', detail: 'action' };
			data = { argv: e.argv[act] };
		}
		else {
			data = {};
			for (let k in (e.body ?? []))
				if (args[e.body[k]] != null)
					data[e.body[k]] = args[e.body[k]];
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
	apply:             { args: { start: 'start' }, call: (req) => call('apply', req) },
	keys:              { args: { generate: 'generate', private_hex: 'private_hex', public_hex: 'public_hex', node_id: 'node_id', vpn_type: 'vpn_type' }, call: (req) => call('keys', req) },
	active:            { args: { tenant: 'tenant', node: 'node', setup_only: 'setup_only', vpn_type: 'vpn_type' }, call: (req) => call('active', req) },
	prepare:           { call: (req) => call('prepare', req) },
	'switch-node':     { args: { node_id: 'node_id' }, call: (req) => call('switch-node', req) },
	'proxy-set':       { args: { policy: 'policy' }, call: (req) => call('proxy-set', req) },
	service:           { args: { action: 'action' }, call: (req) => call('service', req) }
};

return { mynet: methods };
