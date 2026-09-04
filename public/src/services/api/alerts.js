import { http, buildQueryString } from './http';

const base = '/api/alerts';

// Fired alert instances - read + delete only. POST /api/events (see
// events.js) is the sole entry point that creates one; there is no
// PUT/POST here (status-mutation routes are deferred to when a
// notification worker exists to drive them - see the alerting plugin's
// own header comment).
export async function listAlerts(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function getAlert(id) {
  const res = await http(`${base}/${id}`);
  return res.body; // { item }
}

export async function deleteAlert(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}
