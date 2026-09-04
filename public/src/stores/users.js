import { createListStore } from './createListStore';
import * as usersApi from '../services/api/users';

export const useUsersStore = createListStore('users', {
  filters: {
    username: '',
    role_id: '',
    enabled: '',
    search: '',
  },
  sort: 'username:asc',
  listFn: usersApi.listUsers,
  actions: {
    async create(payload) {
      const result = await usersApi.createUser(payload);
      await this.fetchList();
      return result.item;
    },
    async update(id, payload) {
      const result = await usersApi.updateUser(id, payload);
      await this.fetchList();
      return result.item;
    },
    async resetPassword(id, password) {
      return usersApi.resetUserPassword(id, password);
    },
    async remove(id) {
      await usersApi.deleteUser(id);
      await this.fetchList();
    },
    async bulkRemove(ids) {
      const results = await Promise.allSettled(ids.map((id) => usersApi.deleteUser(id)));
      await this.fetchList();
      return { total: ids.length, failed: results.filter((r) => r.status === 'rejected').length };
    },
  },
});
