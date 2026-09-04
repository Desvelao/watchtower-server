import { http, buildQueryString } from './http';

const base = '/api/monitors';

export async function listMonitors() {
  const res = await http(base);
  return res.body; // { items }
}

export async function getMonitor(id) {
  const res = await http(`${base}/${id}`);
  return res.body; // { item }
}

export async function getMonitorHeartbeats(id, query = {}) {
  const res = await http(`${base}/${id}/heartbeats${buildQueryString(query)}`);
  return res.body; // { items }
}
