import Component from './views/AlertsListView.vue';
import { PERMISSIONS } from '../../constants/permissions';
import IconBell from '../../components/common/icons/IconBell.vue';

const plugin = {
  name: 'alerting',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/alerts',
      component: Component,
      name: 'Alerts',
      icon: IconBell,
      permission: PERMISSIONS.ALERTS_READ,
    });
  },
};

export default plugin;
