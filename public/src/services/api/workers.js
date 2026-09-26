import { http, buildQueryString } from './http';
import { downloadFileFromResponse } from '../../utils/download';

const base = '/api/workers';

export async function listWorkers(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function getWorkerHeartbeats(id, query = {}) {
  const res = await http(`${base}/${id}/heartbeats${buildQueryString(query)}`);
  return res.body; // { items }
}

export async function deleteWorker(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

// `query` is expected to be a store's buildExportQuery(...) result - the
// current filters/search/sort (no pagination) plus `format` ('json'|'csv').
export async function exportWorkersFile(query = {}) {
  const response = await http(`${base}/export${buildQueryString(query)}`, { method: 'get' });
  downloadFileFromResponse(response, query.format === 'csv' ? 'export.csv' : 'export.json');
}
