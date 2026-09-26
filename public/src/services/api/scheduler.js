import { http, buildQueryString } from './http';
import { downloadFileFromResponse } from '../../utils/download';

const base = '/api/scheduler';

export async function listTasks(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function getTask(id) {
  const res = await http(`${base}/${id}`);
  return res.body; // { item }
}

export async function createTask(payload) {
  const res = await http(base, { method: 'post', body: payload });
  return res.body; // { message, item }
}

export async function updateTask(id, payload) {
  const res = await http(`${base}/${id}`, { method: 'put', body: payload });
  return res.body; // { message, item }
}

export async function deleteTask(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

export async function previewCron(payload) {
  const res = await http(`${base}/preview-cron`, { method: 'post', body: payload });
  return res.body; // { next_runs }
}

export async function exportTasksFile() {
  const response = await http(`${base}/export`, { method: 'get' });
  downloadFileFromResponse(response, 'export.json');
}

export async function importTasksFile(file) {
  const formData = new FormData();
  formData.append('file', file);
  return http(`${base}/import`, { method: 'post', body: formData });
}
