import { http, buildQueryString } from './http';

const base = '/api/notification_policies';

export async function listPolicies(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function getPolicy(id) {
  const res = await http(`${base}/${id}`);
  return res.body; // { item }
}

export async function createPolicy(payload) {
  const res = await http(base, { method: 'post', body: payload });
  return res.body; // { message, item }
}

export async function updatePolicy(id, payload) {
  const res = await http(`${base}/${id}`, { method: 'put', body: payload });
  return res.body; // { message, item }
}

export async function deletePolicy(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

export async function testPolicyExpression(payload) {
  const res = await http(`${base}/test`, { method: 'post', body: payload });
  return res.body; // { matched }
}

// `ids` (optional array) exports just those policies; omitted/empty exports
// all. `content` is text (a single policy) or a Blob (2+ policies, zipped) -
// http.js's content-type-based body parsing already handles this
// transparently.
export async function exportPolicies(ids) {
  const query = ids && ids.length ? `?ids=${ids.join(',')}` : '';
  const res = await http(`${base}/export${query}`);
  return { content: res.body, contentType: res.headers.get('content-type') || '' };
}

export async function preflightPoliciesImport(file) {
  const formData = new FormData();
  formData.append('file', file);
  const res = await http(`${base}/import/preflight`, { method: 'post', body: formData });
  return res.body; // { items: candidates }
}

export async function commitPoliciesImport(items) {
  const res = await http(`${base}/import`, { method: 'post', body: { items } });
  return res.body; // { results }
}
