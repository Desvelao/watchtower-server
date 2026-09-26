import { http, buildQueryString } from './http';

const base = '/api/users';

export async function listUsers(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function createUser(payload) {
  const res = await http(base, { method: 'post', body: payload });
  return res.body; // { message, item }
}

export async function updateUser(id, payload) {
  const res = await http(`${base}/${id}`, { method: 'put', body: payload });
  return res.body; // { message, item }
}

export async function resetUserPassword(id, password) {
  const res = await http(`${base}/${id}/password`, { method: 'put', body: { password } });
  return res.body; // { message }
}

export async function deleteUser(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

// `ids` (optional array) exports just those users; omitted/empty exports
// all. `content` is a plain object (a single user - http.js already
// parses an `application/json` response body for us) or a Blob (2+ users,
// zipped) - same shape as services/api/rules.js's own exportRules.
export async function exportUsers(ids) {
  const query = ids && ids.length ? `?ids=${ids.join(',')}` : '';
  const res = await http(`${base}/export${query}`);
  return { content: res.body, contentType: res.headers.get('content-type') || '' };
}

export async function preflightUsersImport(file) {
  const formData = new FormData();
  formData.append('file', file);
  const res = await http(`${base}/import/preflight`, { method: 'post', body: formData });
  return res.body; // { items: candidates }
}

export async function commitUsersImport(items) {
  const res = await http(`${base}/import`, { method: 'post', body: { items } });
  return res.body; // { results }
}
