import { http, buildQueryString } from './http';
import { downloadFileFromResponse } from '../../utils/download';

const base = '/api/jobs';

export async function listJobs(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function getJob(id) {
  const res = await http(`${base}/${id}`);
  return res.body; // { item }
}

export async function listJobsFor(type, refId) {
  const res = await http(`${base}/for/${type}/${refId}`);
  return res.body; // { items }
}

export async function deleteJob(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

// `query` is expected to be a store's buildExportQuery(...) result - the
// current filters/search/sort (no pagination) plus `format` ('json'|'csv').
export async function exportJobsFile(query = {}) {
  const response = await http(`${base}/export${buildQueryString(query)}`, { method: 'get' });
  downloadFileFromResponse(response, query.format === 'csv' ? 'export.csv' : 'export.json');
}
