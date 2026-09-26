import { http, buildQueryString } from './http';

const base = '/api/roles';

export async function listRoles(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function createRole(payload) {
  const res = await http(base, { method: 'post', body: payload });
  return res.body; // { message, item }
}

export async function updateRole(id, payload) {
  const res = await http(`${base}/${id}`, { method: 'put', body: payload });
  return res.body; // { message, item }
}

export async function deleteRole(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

// `ids` (optional array) exports just those roles; omitted/empty exports
// all. `content` is a plain object (a single role - http.js already
// parses an `application/json` response body for us) or a Blob (2+ roles,
// zipped) - same shape as services/api/rules.js's own exportRules.
export async function exportRoles(ids) {
  const query = ids && ids.length ? `?ids=${ids.join(',')}` : '';
  const res = await http(`${base}/export${query}`);
  return { content: res.body, contentType: res.headers.get('content-type') || '' };
}

export async function preflightRolesImport(file) {
  const formData = new FormData();
  formData.append('file', file);
  const res = await http(`${base}/import/preflight`, { method: 'post', body: formData });
  return res.body; // { items: candidates }
}

export async function commitRolesImport(items) {
  const res = await http(`${base}/import`, { method: 'post', body: { items } });
  return res.body; // { results }
}
