import { http, buildQueryString } from './http';
import { downloadFileFromResponse } from '../../utils/download';

const base = '/api/observables';

export async function listObservables(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function getObservable(id) {
  const res = await http(`${base}/${id}`);
  return res.body; // { observable }
}

export async function createObservable(payload) {
  const res = await http(base, { method: 'post', body: payload });
  return res.body; // { message, observable }
}

export async function updateObservable(id, payload) {
  const res = await http(`${base}/${id}`, { method: 'put', body: payload });
  return res.body; // { message, observable }
}

export async function deleteObservable(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

export async function exportObservablesFile() {
  const response = await http(`${base}/export`, { method: 'get' });
  downloadFileFromResponse(response, 'export.json');
}

export async function importObservablesFile(file) {
  const formData = new FormData();
  formData.append('file', file);
  return http(`${base}/import`, { method: 'post', body: formData });
}
