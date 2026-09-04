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
