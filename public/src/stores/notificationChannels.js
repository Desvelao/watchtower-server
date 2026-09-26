import { createListStore } from './createListStore';
import * as notificationChannelsApi from '../services/api/notification_channels';

export const useNotificationChannelsStore = createListStore('notification_channels', {
  filters: {
    name: '',
    search: '',
    created_after: '',
    created_before: '',
  },
  sort: 'id:asc',
  listFn: notificationChannelsApi.listNotificationChannels,
  actions: {
    async create(payload) {
      const result = await notificationChannelsApi.createNotificationChannel(payload);
      await this.fetchList();
      return result;
    },
    async update(id, payload) {
      const result = await notificationChannelsApi.updateNotificationChannel(id, payload);
      await this.fetchList();
      return result;
    },
    async remove(id) {
      await notificationChannelsApi.deleteNotificationChannel(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => notificationChannelsApi.deleteNotificationChannel(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
