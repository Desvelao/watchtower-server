import MonitorsView from './views/MonitorsView.vue';
import MonitorDetailView from './views/MonitorDetailView.vue';
import { PERMISSIONS } from '../../constants/permissions';

const plugin = {
  name: 'monitors',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/monitors',
      component: MonitorsView,
      name: 'Monitors',
      icon: 'mdi-robot-outline',
      permission: PERMISSIONS.MONITORS_READ,
    });
    core.router.addRoute({
      path: '/monitors/:id',
      component: MonitorDetailView,
      props: true,
      meta: { permission: PERMISSIONS.MONITORS_READ },
    });
  },
};

export default plugin;
