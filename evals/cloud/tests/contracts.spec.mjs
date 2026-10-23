import { test, expect, request } from '@playwright/test';
import { createReferenceService } from '../lib/reference.mjs';
import { upload, pack, policy, fingerprint } from '../lib/fixtures.mjs';
import { gradeFacts } from '../lib/grading.mjs';
let service, client;
test.beforeEach(async () => {
  service = await createReferenceService({ absent: process.env.OPENBRIDGE_EVAL_REFERENCE === 'absent' });
  client = await request.newContext({ baseURL: service.url, timeout: 5_000,
    extraHTTPHeaders: { Authorization: 'Fixture uid_alex' } });
  expect((await client.get('/health')).status()).toBe(200);
});
test.afterEach(async () => { await client?.dispose(); await service?.close(); });

test('[F1] finalized upload is ready only after the controlled storage barrier', async () => {
  const body = upload('sync_today');
  const pending = client.post('/v1/meetings/ingest', { data: body,
    headers: { 'Idempotency-Key': `${pack.library_id}/${body.session_id}/${body.original_revision_id}` } });
  await service.processing();
  expect(service.snapshot().ready).toBe(false);
  expect(service.snapshot().receipt).toBeNull();
  service.release();
  const response = await pending;
  expect(response.status()).toBe(200);
  const receipt = await response.json();
  expect(receipt.status).toBe('ready');
  const state = service.snapshot();
  expect(state.originals).toEqual(body.segments);
  expect(fingerprint(state.originals)).toBe(body.source_fingerprint);
  expect(state.vectors).toHaveLength(2);
  for (const vector of state.vectors) expect(vector).toHaveLength(768);
  expect(gradeFacts('F1', state.facts)).toEqual({ status: 'pass', findings: [] });
  expect(state.notificationIntent).toEqual({ receipt_id: receipt.receipt_id, text: policy.notification });
  // This is a mock client intent, not Notification Center evidence.
});

test('[N04] replay retains one revision and receipt; changed payload conflicts', async () => {
  service.release(); const body = upload('sync_today');
  const options = { data: body, headers: { 'Idempotency-Key': 'same-fixture-operation' } };
  const first = await client.post('/v1/meetings/ingest', options);
  expect(first.status()).toBe(200);
  expect(await (await client.post('/v1/meetings/ingest', options)).json()).toEqual(await first.json());
  const changed = { ...body, retention: { policy: 'keepUntilDeleted', expires_at: null } };
  expect((await client.post('/v1/meetings/ingest', { ...options, data: changed })).status()).toBe(409);
  expect(service.snapshot().revisionCount).toBe(1);
});

test('[N05] invalid original segment IDs fail before a content write', async () => {
  service.release();
  for (const id of ['part/1', '.', '..', '__reserved__', '', 'x'.repeat(129), 'é'.repeat(65)]) {
    const body = upload('api_yesterday'); body.segments[0].id = id;
    body.source_fingerprint = fingerprint(body.segments); body.original_revision_id = `sha256:${body.source_fingerprint}`;
    expect((await client.post('/v1/meetings/ingest', { data: body })).status()).toBe(422);
    expect(service.snapshot().revisionCount).toBe(0);
  }
});
