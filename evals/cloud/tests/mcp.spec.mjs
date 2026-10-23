import { test, expect, request } from '@playwright/test';
import { createReferenceService } from '../lib/reference.mjs';
import { policy } from '../lib/fixtures.mjs';
import { gradeFacts } from '../lib/grading.mjs';
test('[F3] HTTP JSON-RPC tool call returns today’s cited architecture and actions', async () => {
  const service = await createReferenceService({ absent: process.env.OPENBRIDGE_EVAL_REFERENCE === 'absent' });
  const client = await request.newContext({ baseURL: service.url, timeout: 5_000,
    extraHTTPHeaders: { Authorization: 'Fixture uid_alex' } });
  try {
    expect((await client.get('/health')).status()).toBe(200);
    const invocation = { jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name: 'search_meetings', arguments: { query: policy.questions.F3,
        date_from: '2026-10-10T04:00:00Z', date_to: '2026-10-11T04:00:00Z', timezone: 'America/New_York' } } };
    const response = await client.post('/mcp', { data: invocation });
    expect(response.status()).toBe(200);
    const result = await response.json();
    expect(result.id).toBe(1);
    expect(service.snapshot().lastInvocation).toEqual(invocation);
    expect(gradeFacts('F3', result.result.facts)).toEqual({ status: 'pass', findings: [] });
    // An APIRequestContext is not an actual Codex client or an OAuth proof.
  } finally { await client.dispose(); await service.close(); }
});
