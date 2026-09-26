import JobsListView from './views/JobsListView.vue';
import { PERMISSIONS } from '../../constants/permissions';
import IconTrigger from '../../components/common/icons/IconTrigger.vue';

const plugin = {
  name: 'jobs',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/jobs',
      component: JobsListView,
      name: 'Jobs',
      icon: IconTrigger,
      permission: PERMISSIONS.JOBS_READ,
    });
  },
};

export default plugin;
