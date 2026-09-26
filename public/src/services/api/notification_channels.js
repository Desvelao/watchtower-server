import { http, buildQueryString } from './http';
import { downloadFileFromResponse } from '../../utils/download';

const base = '/api/notification_channels';

export async function listNotificationChannels(query = {}) {
  const res = await http(`${base}${buildQueryString(query)}`);
  return res.body; // { items, total_items }
}

export async function getNotificationChannel(id) {
  const res = await http(`${base}/${id}`);
  return res.body; // { item }
}

export async function createNotificationChannel(payload) {
  const res = await http(base, { method: 'post', body: payload });
  return res.body; // { message, data }
}

export async function updateNotificationChannel(id, payload) {
  const res = await http(`${base}/${id}`, { method: 'put', body: payload });
  return res.body; // { message, data }
}

export async function deleteNotificationChannel(id) {
  const res = await http(`${base}/${id}`, { method: 'delete' });
  return res.body; // { message }
}

export async function exportNotificationChannelsFile() {
  const response = await http(`${base}/export`, { method: 'get' });
  downloadFileFromResponse(response, 'export.json');
}

export async function importNotificationChannelsFile(file) {
  const formData = new FormData();
  formData.append('file', file);
  return http(`${base}/import`, { method: 'post', body: formData });
}
