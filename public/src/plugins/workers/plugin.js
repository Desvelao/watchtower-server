import WorkersView from './views/WorkersView.vue';
import WorkerDetailView from './views/WorkerDetailView.vue';
import { PERMISSIONS } from '../../constants/permissions';
import IconRobot from '../../components/common/icons/IconRobot.vue';

const plugin = {
  name: 'workers',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/workers',
      component: WorkersView,
      name: 'Workers',
      icon: IconRobot,
      permission: PERMISSIONS.WORKERS_READ,
    });
    core.router.addRoute({
      path: '/workers/:id',
      component: WorkerDetailView,
      props: true,
      meta: { permission: PERMISSIONS.WORKERS_READ },
    });
  },
};

export default plugin;
