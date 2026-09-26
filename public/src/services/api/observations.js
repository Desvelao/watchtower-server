import { http, buildQueryString } from './http';
import { downloadFileFromResponse } from '../../utils/download';

const base = '/api/observations';

export async function listObservations(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

// There is no GET /api/observations/:id route - reuse the list route's
// existing `id` filter instead (see server/plugins/entities/
// observations_routes.lua's where_params).
export async function getObservation(id) {
  const { items } = await listObservations({ id });
  return { item: items[0] || null };
}

export async function deleteObservation(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

// `query` is expected to be a store's buildExportQuery(...) result - the
// current filters/search/sort (no pagination) plus `format` ('json'|'csv').
export async function exportObservationsFile(query = {}) {
  const response = await http(`${base}/export${buildQueryString(query)}`, { method: 'get' });
  downloadFileFromResponse(response, query.format === 'csv' ? 'export.csv' : 'export.json');
}
