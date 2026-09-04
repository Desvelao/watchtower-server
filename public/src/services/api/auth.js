import { http, buildQueryString } from './http';

const base = '/api/auth';

export async function login(username, password) {
  const res = await http(`${base}/login`, {
    method: 'post',
    body: { username, password },
    skipAuth: true,
  });
  return res.body; // { message, token, role }
}

export async function getMe() {
  const res = await http(`${base}/me`);
  return res.body; // { username, role, permissions }
}

export async function listApiKeys(query = {}) {
  const res = await http(`${base}/api_key${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function createApiKey(label, permissions, expiresInDays) {
  const res = await http(`${base}/api_key`, {
    method: 'post',
    body: { label, permissions, expires_in_days: expiresInDays || undefined },
  });
  return res.body; // { message, api_key }
}

export async function updateApiKey(kid, label) {
  const res = await http(`${base}/api_key/${encodeURIComponent(kid)}`, {
    method: 'put',
    body: { label },
  });
  return res.body; // { message, id, label }
}

export async function revokeApiKey(kid) {
  const res = await http(`${base}/api_key/${encodeURIComponent(kid)}/revoke`, {
    method: 'post',
  });
  return res.body; // { message, id }
}

export async function deleteApiKey(kid) {
  const res = await http(`${base}/api_key/${encodeURIComponent(kid)}`, {
    method: 'delete',
  });
  return res.body; // { message, id }
}
