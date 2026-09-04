import { http, buildQueryString } from './http';

const base = '/api/events';

export async function listEvents(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function getEvent(id) {
  const res = await http(`${base}/${id}`);
  return res.body; // { item }
}

export async function createEvent(payload) {
  const res = await http(base, { method: 'post', body: payload });
  return res.body; // { message, item }
}

export async function deleteEvent(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}
