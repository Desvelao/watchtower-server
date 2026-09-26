import { http, buildQueryString } from './http';
import { downloadFileFromResponse } from '../../utils/download';

const base = '/api/observable_types';

export async function listObservableTypes(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function getObservableType(id) {
  const res = await http(`${base}/${id}`);
  return res.body; // { item }
}

export async function createObservableType(payload) {
  const res = await http(base, { method: 'post', body: payload });
  return res.body; // { item }
}

export async function updateObservableType(id, payload) {
  const res = await http(`${base}/${id}`, { method: 'put', body: payload });
  return res.body; // { item }
}

export async function deleteObservableType(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

export async function exportObservableTypesFile() {
  const response = await http(`${base}/export`, { method: 'get' });
  downloadFileFromResponse(response, 'export.json');
}

export async function importObservableTypesFile(file) {
  const formData = new FormData();
  formData.append('file', file);
  return http(`${base}/import`, { method: 'post', body: formData });
}
