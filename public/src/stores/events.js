import { createListStore } from './createListStore';
import * as eventsApi from '../services/api/events';
import { relativeDateKeyword } from '../utils/date';

export const useEventsStore = createListStore('events', {
  filters: {
    id: '',
    source: '',
    tags: '',
    search: '',
    created_after: relativeDateKeyword(24),
    created_before: '',
  },
  sort: 'created_at:desc',
  listFn: eventsApi.listEvents,
  actions: {
    async create(payload) {
      const result = await eventsApi.createEvent(payload);
      await this.fetchList();
      return result.item;
    },
    async remove(id) {
      await eventsApi.deleteEvent(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => eventsApi.deleteEvent(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
