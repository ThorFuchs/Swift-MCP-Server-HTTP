// SPDX-License-Identifier: Apache-2.0
import { createServer } from 'node:http';
import { once } from 'node:events';
import { setTimeout as sleep } from 'node:timers/promises';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { exercise } from './probe-core-n32-wire.mjs';

const SUB = 'io.modelcontextprotocol/subscriptionId';
const budgets = { open: 500, rpc: 1000, mutation: 2000, observe: 120, quiet: 50, preflight: 20 };
async function withMock(fault, action) {
  const subscribers = new Map();
  const names = { prompts: ['base_prompt'], tools: ['base_tool'] };
  const emit = (res, frame) => res.write('data: ' + JSON.stringify(frame) + '\r\n\r\n');
  const event = (method, id, extra = {}) => ({ jsonrpc: '2.0', method, params: { _meta: { [SUB]: id }, ...extra } });
  const server = createServer(async (req, res) => {
    try {
      const chunks = []; for await (const c of req) chunks.push(c);
      const { id, method, params } = JSON.parse(Buffer.concat(chunks));
      assert.equal(req.headers['mcp-method'], method);
      assert.equal(req.headers['mcp-protocol-version'], '2026-07-28');
      assert.equal(params._meta['io.modelcontextprotocol/protocolVersion'], '2026-07-28');
      const reply = result => { res.writeHead(200, { 'content-type': 'text/event-stream' }); emit(res, { jsonrpc: '2.0', id, result: { resultType: 'complete', ...result } }); res.end(); };
      if (method === 'server/discover') return reply({ supportedVersions: ['2026-07-28'], capabilities: { prompts: { listChanged: true }, tools: { listChanged: true } } });
      if (method.endsWith('/list')) { const kind = method.split('/')[0]; return reply({ [kind]: names[kind].map(name => ({ name })) }); }
      if (method === 'subscriptions/listen') {
        const kind = params.notifications.promptsListChanged ? 'prompts' : 'tools';
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        subscribers.set(kind, { id, res }); res.on('close', () => subscribers.delete(kind));
        const ack = event('notifications/subscriptions/acknowledged', fault === 'wrongAck' ? id + 1 : id,
          { notifications: fault === 'wrongFilter' ? { resourcesListChanged: true } : params.notifications });
        if (fault === 'pretrigger' && kind === 'prompts') { emit(res, ack); emit(res, event('notifications/prompts/list_changed', id)); }
        else { const bytes = 'data: ' + JSON.stringify(ack) + '\r\n\r\n'; res.write(bytes.slice(0, 13)); res.write(bytes.slice(13)); }
        if (fault === 'earlyEOF') res.end();
        return;
      }
      if (method === 'tools/call') {
        assert.equal(req.headers['mcp-name'], params.name);
        const kind = params.name.includes('prompt') ? 'prompts' : 'tools';
        if (fault === 'slow' && kind === 'prompts') await sleep(650);
        if (fault === 'badMutation') return reply({ isError: true });
        if (fault !== 'noChange') names[kind].push(kind === 'prompts' ? 'test_dynamic_prompt' : 'test_dynamic_tool');
        const sub = subscribers.get(kind);
        if (fault !== 'missing') emit(sub.res, event(`notifications/${kind}/list_changed`, fault === 'wrongId' ? sub.id + 1 : sub.id));
        if (fault === 'cross') { const other = subscribers.get(kind === 'prompts' ? 'tools' : 'prompts'); emit(other.res, event(`notifications/${kind}/list_changed`, other.id)); }
        if (fault === 'duplicate') emit(sub.res, event(`notifications/${kind}/list_changed`, sub.id));
        return reply({ content: [{ type: 'text', text: 'Mutation triggered' }] });
      }
      res.writeHead(404).end();
    } catch (error) { res.destroy(error); }
  });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  try {
    await action(`http://127.0.0.1:${server.address().port}/mcp`);
    for (let i = 0; i < 100 && subscribers.size; i++) await sleep(10);
    assert.equal(subscribers.size, 0, 'subscription sockets must be closed');
  } finally { server.closeAllConnections(); await new Promise(r => server.close(r)); }
}
test('real HTTP/SSE framing and mutation beyond opening window', async () => {
  await withMock('slow', async url => {
    const result = await exercise(url, budgets);
    assert.equal(result.outcome, 'PASS_N32_WIRE');
    assert.equal(result.changes.length, 2);
    assert.equal(result.streamsClosed, 2);
    assert.ok(result.changes[0].mutationMs >= 500);
  });
});
for (const [fault, expected] of Object.entries({ wrongAck: /wrong notification/, wrongFilter: /wrong acknowledged filter/, pretrigger: /unexpected\/cross-filter/, earlyEOF: /subscription closed early/, badMutation: /invalid completion/, noChange: /unexpected catalog contents/, missing: /observation: deadline/, wrongId: /wrong notification/, cross: /unexpected\/cross-filter/, duplicate: /unexpected\/cross-filter/ })) {
  test(`reject ${fault} and close streams`, async () => withMock(fault, url => assert.rejects(exercise(url, budgets), expected)));
}
test('refuse external endpoint before network access', async () => assert.rejects(exercise('https://example.com/mcp', budgets), /non-fixture endpoint/));
