import { createListStore } from './createListStore';
import * as rolesApi from '../services/api/roles';

// Roles are few and unpaginated (RolesListView.vue never shows pagination
// controls) - reuses createListStore for consistency with every other
// resource store, and still supports search/filtering the same way.
export const useRolesStore = createListStore('roles', {
  filters: {
    search: '',
    permission: '',
  },
  sort: 'name:asc',
  listFn: rolesApi.listRoles,
  actions: {
    async create(payload) {
      const result = await rolesApi.createRole(payload);
      await this.fetchList();
      return result.item;
    },
    async update(id, payload) {
      const result = await rolesApi.updateRole(id, payload);
      await this.fetchList();
      return result.item;
    },
    async remove(id) {
      await rolesApi.deleteRole(id);
      await this.fetchList();
    },
  },
});
