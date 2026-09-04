import Component from './views/AlertsListView.vue';
import { PERMISSIONS } from '../../constants/permissions';

const plugin = {
  name: 'alerting',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/alerts',
      component: Component,
      name: 'Alerts',
      icon: 'mdi-bell-outline',
      permission: PERMISSIONS.ALERTS_READ,
    });
  },
};

export default plugin;
