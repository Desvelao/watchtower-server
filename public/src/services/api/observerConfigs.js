import { http, buildQueryString } from './http';
import { downloadFileFromResponse } from '../../utils/download';
import { listJobsFor } from './jobs';

const base = '/api/observer_configs';

const TEST_POLL_INTERVAL_MS = 1000;
const TEST_POLL_TIMEOUT_MS = 30000;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// The test_requests POST routes below only enqueue the test (see
// server/plugins/observer_configs/plugin.lua) - a worker (standalone or
// embedded) claims it as a type='observer_test' job and runs the actual
// run the test off the request cycle. This polls GET /api/jobs/for/observer_test/:id
// until that job is acknowledged (resolves with the observed {ok, data}) or
// error (rejects), or TEST_POLL_TIMEOUT_MS elapses with no worker having
// claimed it - most likely because no worker is currently running.
async function pollTestResult(id) {
  const deadline = Date.now() + TEST_POLL_TIMEOUT_MS;
  while (Date.now() < deadline) {
    const { items } = await listJobsFor('observer_test', id);
    const job = items && items[0];
    if (job) {
      if (job.status === 'acknowledged') {
        return job.result ?? null;
      }
      if (job.status === 'error') {
        throw new Error(job.message || 'Test failed');
      }
    }
    await sleep(TEST_POLL_INTERVAL_MS);
  }
  throw new Error('Timed out waiting for a worker to run this test - is a worker running?');
}

export async function listObserverConfigs(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

// There is no GET /:id route - reuse the list route's existing `id` filter
// instead (see server/plugins/observer_configs/plugin.lua).
export async function getObserverConfig(id) {
  const { items } = await listObserverConfigs({ id });
  return { item: items[0] || null };
}

export async function createObserverConfig(payload) {
  const res = await http(base, { method: 'post', body: payload });
  return res.body; // { message, item }
}

export async function updateObserverConfig(id, payload) {
  const res = await http(`${base}/${id}`, { method: 'put', body: payload });
  return res.body; // { message, item }
}

export async function deleteObserverConfig(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

export async function testObserverConfig(id, payload) {
  const res = await http(`${base}/${id}/test`, { method: 'post', body: payload });
  const data = await pollTestResult(res.body.id);
  return { ok: true, data };
}

export async function testUnregisteredObserverConfig(payload) {
  const res = await http(`${base}/test`, { method: 'post', body: payload });
  const data = await pollTestResult(res.body.id);
  return { ok: true, data };
}

export async function testAllObserverConfigs(payload) {
  const res = await http(`${base}/test/_all`, { method: 'post', body: payload });
  const data = await pollTestResult(res.body.id);
  return { ok: true, data };
}

export async function exportObserverConfigsFile() {
  const response = await http(`${base}/export`, { method: 'get' });
  downloadFileFromResponse(response, 'export.json');
}

export async function importObserverConfigsFile(file) {
  const formData = new FormData();
  formData.append('file', file);
  return http(`${base}/import`, { method: 'post', body: formData });
}
