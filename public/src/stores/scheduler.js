import { createListStore } from './createListStore';
import * as schedulerApi from '../services/api/scheduler';

export const useSchedulerStore = createListStore('scheduler', {
  filters: {
    type: '',
    observable_type_id: '',
    schedule_type: '',
    enabled: '',
    search: '',
    created_after: '',
    created_before: '',
  },
  sort: 'id:asc',
  listFn: schedulerApi.listTasks,
  actions: {
    async create(payload) {
      const result = await schedulerApi.createTask(payload);
      await this.fetchList();
      return result.item;
    },
    async update(id, payload) {
      const result = await schedulerApi.updateTask(id, payload);
      await this.fetchList();
      return result.item;
    },
    async remove(id) {
      await schedulerApi.deleteTask(id);
      await this.fetchList();
    },
    async runNow(id) {
      const result = await schedulerApi.updateTask(id, { run_now: true });
      await this.fetchList();
      return result.item;
    },
  },
});
