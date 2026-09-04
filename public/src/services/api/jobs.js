import { http, buildQueryString } from './http';

const base = '/api/jobs';

export async function listJobs(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function listJobStats(type) {
  const res = await http(`${base}/stats${buildQueryString({ type })}`);
  return res.body; // { items }
}
