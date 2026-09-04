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
