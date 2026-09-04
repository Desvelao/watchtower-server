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
