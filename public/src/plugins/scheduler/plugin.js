import SchedulerTasksListView from './views/SchedulerTasksListView.vue';
import SchedulerTaskFormView from './views/SchedulerTaskFormView.vue';
import { PERMISSIONS } from '../../constants/permissions';
import IconClock from '../../components/common/icons/IconClock.vue';

const plugin = {
  name: 'scheduler',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/scheduler',
      component: SchedulerTasksListView,
      name: 'Scheduler',
      icon: IconClock,
      permission: PERMISSIONS.SCHEDULER_READ,
    });
    core.router.addRoute({
      path: '/scheduler/new',
      component: SchedulerTaskFormView,
      meta: { permission: PERMISSIONS.SCHEDULER_CREATE },
    });
    core.router.addRoute({
      path: '/scheduler/:id/edit',
      component: SchedulerTaskFormView,
      props: true,
      meta: { permission: PERMISSIONS.SCHEDULER_UPDATE },
    });
  },
};

export default plugin;
