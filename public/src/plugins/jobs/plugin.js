import JobsListView from './views/JobsListView.vue';
import { PERMISSIONS } from '../../constants/permissions';

const plugin = {
  name: 'jobs',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/jobs',
      component: JobsListView,
      name: 'Jobs',
      icon: 'mdi-truck-delivery-outline',
      permission: PERMISSIONS.JOBS_READ,
    });
  },
};

export default plugin;
