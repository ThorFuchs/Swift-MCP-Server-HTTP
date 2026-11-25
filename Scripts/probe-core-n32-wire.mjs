// SPDX-License-Identifier: Apache-2.0
// Independent N3.2 wire probe. No SDK or referee imports.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { closeSync, openSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';

const VERSION = '2026-07-28';
const SUB = 'io.modelcontextprotocol/subscriptionId';
const LIMIT = 8 * 1024 * 1024;
const TYPES = ['prompts', 'tools'];
const FILTER = { prompts: 'promptsListChanged', tools: 'toolsListChanged' };
const DYNAMIC = { prompts: 'test_dynamic_prompt', tools: 'test_dynamic_tool' };
const TRIGGER = { prompts: 'test_trigger_prompt_change', tools: 'test_trigger_tool_change' };
const DEFAULTS = { open: 5000, rpc: 10000, mutation: 30000, observe: 1500, quiet: 1500, preflight: 100 };
function need(ok, message) { if (!ok) throw new Error(message); }
function object(x) { return x !== null && typeof x === 'object' && !Array.isArray(x); }
function notification(frame, method, id) {
  need(object(frame) && frame.jsonrpc === '2.0' && frame.method === method && !('id' in frame) &&
    !('result' in frame) && !('error' in frame) && frame.params?._meta?.[SUB] === id, `wrong notification or subscription ID: ${method}`);
}
function validateURL(url) {
  const u = new URL(url);
  need(u.protocol === 'http:' && u.hostname === '127.0.0.1' && u.port && u.pathname === '/mcp' && !u.username && !u.password && !u.search && !u.hash, 'non-fixture endpoint');
  return u.href;
}
async function post(url, method, id, params, controller) {
  const headers = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream',
    'MCP-Protocol-Version': VERSION, 'Mcp-Method': method };
  if (method === 'tools/call') headers['Mcp-Name'] = params.name;
  const response = await fetch(url, { method: 'POST', headers, redirect: 'error', signal: controller.signal,
    body: JSON.stringify({ jsonrpc: '2.0', id, method, params: { ...params, _meta: {
      'io.modelcontextprotocol/protocolVersion': VERSION,
      'io.modelcontextprotocol/clientInfo': { name: 'n32-wire-probe', version: '1.0.0' },
      'io.modelcontextprotocol/clientCapabilities': {} } } }) });
  need(response.status === 200 && response.body, `${method}: HTTP ${response.status}`);
  return response;
}
async function* sse(response) {
  need(response.headers.get('content-type')?.split(';')[0].trim() === 'text/event-stream', 'expected SSE');
  const reader = response.body.getReader(), decoder = new TextDecoder('utf-8', { fatal: true });
  let buffer = '', data = [], bytes = 0, frames = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) { need(!buffer && !data.length && !decoder.decode(), 'truncated SSE'); return; }
      bytes += value.byteLength; need(bytes <= LIMIT, 'SSE byte limit');
      buffer += decoder.decode(value, { stream: true });
      let pos;
      while ((pos = buffer.indexOf('\n')) >= 0) {
        const line = buffer.slice(0, pos).replace(/\r$/, ''); buffer = buffer.slice(pos + 1);
        if (!line) {
          if (data.length) { need(++frames <= 64, 'SSE frame limit'); const frame = JSON.parse(data.join('\n')); data = []; yield frame; }
        } else if (line === 'data' || line.startsWith('data:')) data.push(line === 'data' ? '' : line.slice(5).replace(/^ /, ''));
        else if (!line.startsWith(':')) need(/^(event|id|retry)(:|$)/.test(line), 'unexpected SSE field');
      }
    }
  } finally { try { await reader.cancel(); } finally { reader.releaseLock(); } }
}
async function jsonBody(response) {
  const reader = response.body.getReader(); let size = 0; const chunks = [];
  try {
    for (;;) { const { done, value } = await reader.read(); if (done) break;
      size += value.byteLength; need(size <= LIMIT, 'JSON byte limit'); chunks.push(value); }
    return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(chunks)));
  } finally { try { await reader.cancel(); } finally { reader.releaseLock(); } }
}
async function rpc(url, method, id, params, budget) {
  const ctl = new AbortController(); const timer = setTimeout(() => ctl.abort(new Error(`${method}: deadline`)), budget);
  try {
    const response = await post(url, method, id, params, ctl); let frame;
    const type = response.headers.get('content-type')?.split(';')[0].trim();
    if (type === 'application/json') frame = await jsonBody(response);
    else {
      for await (const f of sse(response)) { frame = f; break; }
    }
    need(object(frame) && frame.jsonrpc === '2.0' && frame.id === id && !('error' in frame) &&
      !('method' in frame) && object(frame.result) && frame.result.resultType === 'complete' && frame.result.isError !== true, `${method}: invalid completion`);
    return frame.result;
  } finally { clearTimeout(timer); ctl.abort(); }
}
async function waitFor(test, ms, label) {
  const until = performance.now() + ms;
  while (!test()) { need(performance.now() < until, `${label}: deadline`); await sleep(5); }
}
async function subscribe(url, kind, id, budget) {
  const ctl = new AbortController(); const state = { kind, id, frames: [], error: null, closing: false };
  const timer = setTimeout(() => ctl.abort(new Error('subscription opening deadline')), budget);
  let pump;
  state.close = async () => { state.closing = true; ctl.abort(); if (pump) await pump; };
  try {
    const response = await post(url, 'subscriptions/listen', id, { notifications: { [FILTER[kind]]: true } }, ctl);
    pump = (async () => {
      try {
        for await (const frame of sse(response)) state.frames.push({ frame, at: performance.now() });
        if (!state.closing) throw new Error('subscription closed early');
      } catch (error) { if (!state.closing) state.error = error; }
    })();
    await waitFor(() => { if (state.error) throw state.error; return state.frames.length > 0; }, budget, 'subscription ACK');
    const ack = state.frames[0].frame;
    notification(ack, 'notifications/subscriptions/acknowledged', id);
    need(object(ack.params.notifications) && Object.keys(ack.params.notifications).length === 1 && ack.params.notifications[FILTER[kind]] === true, 'wrong acknowledged filter');
    return state;
  } catch (error) { await state.close(); throw error; }
  finally { clearTimeout(timer); }
}
export async function exercise(rawURL, budgets = DEFAULTS) {
  const url = validateURL(rawURL); let next = 10; const states = []; const changes = [];
  const call = (method, params = {}, budget = budgets.rpc) => rpc(url, method, next++, params, budget);
  async function list(kind) {
    const names = new Set(), cursors = new Set(); let cursor;
    for (let page = 0; page < 32; page++) {
      const result = await call(`${kind}/list`, cursor === undefined ? {} : { cursor });
      need(Array.isArray(result[kind]), `missing ${kind} list`);
      for (const item of result[kind]) { need(typeof item.name === 'string' && !names.has(item.name), 'invalid/duplicate catalog name'); names.add(item.name); }
      if (result.nextCursor === undefined) return [...names].sort();
      cursor = result.nextCursor; need(typeof cursor === 'string' && !cursors.has(cursor), 'invalid/repeated cursor'); cursors.add(cursor);
    }
    throw new Error('pagination limit');
  }
  function counts(expected) {
    for (let i = 0; i < states.length; i++) {
      const s = states[i]; if (s.error) throw s.error;
      need(s.frames.length <= expected[i], `unexpected/cross-filter frame on ${s.kind}`);
    }
    return states.every((s, i) => s.frames.length === expected[i]);
  }
  const equalNames = (actual, expected) => need(JSON.stringify(actual) === JSON.stringify([...expected].sort()), 'unexpected catalog contents');
  const allLists = async () => ({ prompts: await list('prompts'), tools: await list('tools') });
  const discovered = await call('server/discover');
  need(discovered.supportedVersions?.includes(VERSION) && TYPES.every(k => discovered.capabilities?.[k]?.listChanged === true), 'missing discovery capabilities');
  const before = await allLists();
  for (const kind of TYPES) need(!before[kind].includes(DYNAMIC[kind]), 'fixture not fresh');
  const expectedNames = { prompts: [...before.prompts], tools: [...before.tools] };
  try {
    for (const kind of TYPES) states.push(await subscribe(url, kind, next++, budgets.open));
    await sleep(budgets.preflight); need(counts([1, 1]), 'missing initial ACK');
    for (let i = 0; i < TYPES.length; i++) {
      const kind = TYPES[i], expected = i === 0 ? [2, 1] : [2, 2];
      const started = performance.now();
      const result = await call('tools/call', { name: TRIGGER[kind], arguments: {} }, budgets.mutation);
      const completed = performance.now();
      need(result.content?.some(x => x.type === 'text' && x.text === 'Mutation triggered'), 'mutation did not report success');
      // The pumps keep both acknowledged streams open throughout the RPC.
      // A valid notification may already be buffered when the RPC completes.
      await waitFor(() => counts(expected), budgets.observe, `${kind} observation`);
      const event = states[i].frames[1];
      notification(event.frame, `notifications/${kind}/list_changed`, states[i].id);
      need(event.at >= started && event.at <= completed + budgets.observe, 'notification outside observation interval');
      expectedNames[kind].push(DYNAMIC[kind]);
      const after = await allLists();
      for (const k of TYPES) equalNames(after[k], expectedNames[k]);
      need(counts(expected), 'notification inventory changed');
      changes.push({ kind, mutationMs: completed - started, observedMs: event.at - started, after, ack: states[i].frames[0].frame, notification: event.frame });
    }
    await sleep(budgets.quiet); need(counts([2, 2]), 'notification inventory changed during quiet window');
  } finally { await Promise.all(states.map(s => s.close())); }
  for (const kind of TYPES) equalNames(await list(kind), expectedNames[kind]);
  return { outcome: 'PASS_N32_WIRE', before, changes, streamsClosed: states.length, postCloseListings: true, budgets };
}
async function runFixture(binary, out) {
  await mkdir(out); const nonce = 'n32-' + randomUUID(); const ready = resolve(out, 'ready.json');
  const stdout = openSync(resolve(out, 'fixture.stdout'), 'wx'), stderr = openSync(resolve(out, 'fixture.stderr'), 'wx');
  let child;
  try { child = spawn(binary, ['--host', '127.0.0.1', '--port', '0', '--ready-file', ready, '--nonce', nonce], { stdio: ['ignore', stdout, stderr] }); }
  finally { closeSync(stdout); closeSync(stderr); }
  let exit; const joined = new Promise(r => { child.once('error', error => { exit = { error: String(error) }; r(exit); }); child.once('exit', (code, signal) => { exit = { code, signal }; r(exit); }); });
  let receipt;
  try {
    let info; const end = performance.now() + 60000;
    while (!info) { need(!exit && performance.now() < end, 'fixture readiness failed');
      try { info = JSON.parse(await readFile(ready, 'utf8')); } catch (e) { if (e.code !== 'ENOENT') throw e; await sleep(50); } }
    need(info.nonce === nonce && info.pid === child.pid && info.protocolVersion === VERSION && info.readinessSchema === 'swift-mcp-fixture-ready-v2', 'readiness mismatch');
    receipt = await exercise(info.url);
  } finally {
    if (!exit) child.kill('SIGTERM');
    const timeout = setTimeout(() => { if (!exit) child.kill('SIGKILL'); }, 15000);
    try { await joined; } finally { clearTimeout(timeout); }
    await writeFile(resolve(out, 'fixture-exit.json'), JSON.stringify(exit, null, 2) + '\n');
  }
  need(exit?.code === 0 && exit.signal === null, 'fixture exit failure');
  need((await readFile(resolve(out, 'fixture.stderr'), 'utf8')).split(/\r?\n/).filter(l => l === 'FIXTURE_STOPPED started=2 joined=2 active=0').length === 1, 'fixture ownership receipt missing');
  await writeFile(resolve(out, 'wire-receipt.json'), JSON.stringify({ ...receipt, fixtureExit: exit }, null, 2) + '\n');
  console.log('PASS_N32_WIRE: 2 correlated notifications, exact catalog changes, filter isolation, closed streams, joined fixture');
}
if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  try { need(process.argv.length === 4, 'usage: node probe-core-n32-wire.mjs FIXTURE EVIDENCE_DIR'); await runFixture(resolve(process.argv[2]), resolve(process.argv[3])); }
  catch (error) { console.error(error); process.exitCode = 1; }
}
