import { http, buildQueryString } from './http';

const base = '/api/rules';

export async function listRules(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function getRule(id) {
  const res = await http(`${base}/${id}`);
  return res.body; // { item }
}

export async function createRule(payload) {
  const res = await http(base, { method: 'post', body: payload });
  return res.body; // { message, item }
}

export async function updateRule(id, payload) {
  const res = await http(`${base}/${id}`, { method: 'put', body: payload });
  return res.body; // { message, item }
}

export async function deleteRule(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

export async function testRule(payload) {
  const res = await http(`${base}/test`, { method: 'post', body: payload });
  return res.body; // { matches }
}

export async function testExpression(payload) {
  const res = await http(`${base}/test-expression`, { method: 'post', body: payload });
  return res.body; // { matched }
}

// `ids` (optional array) exports just those rules; omitted/empty exports
// all. `content` is text (a single rule) or a Blob (2+ rules, zipped) -
// http.js's content-type-based body parsing already handles this
// transparently.
export async function exportRules(ids) {
  const query = ids && ids.length ? `?ids=${ids.join(',')}` : '';
  const res = await http(`${base}/export${query}`);
  return { content: res.body, contentType: res.headers.get('content-type') || '' };
}

export async function preflightRulesImport(file) {
  const formData = new FormData();
  formData.append('file', file);
  const res = await http(`${base}/import/preflight`, { method: 'post', body: formData });
  return res.body; // { items: candidates }
}

export async function commitRulesImport(items) {
  const res = await http(`${base}/import`, { method: 'post', body: { items } });
  return res.body; // { results }
}
