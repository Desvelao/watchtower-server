import { http, buildQueryString } from './http';
import { downloadFileFromResponse } from '../../utils/download';

const base = '/api/alert_deliveries';

export async function listDeliveries(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

// `query` is expected to be a store's buildExportQuery(...) result - the
// current filters/search/sort (no pagination) plus `format` ('json'|'csv').
export async function exportDeliveriesFile(query = {}) {
  const response = await http(`${base}/export${buildQueryString(query)}`, { method: 'get' });
  downloadFileFromResponse(response, query.format === 'csv' ? 'export.csv' : 'export.json');
}
