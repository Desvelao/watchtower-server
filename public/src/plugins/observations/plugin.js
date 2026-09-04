import Component from './views/List.vue';
import { PERMISSIONS } from '../../constants/permissions';

const plugin = {
  name: 'observations',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/observations',
      component: Component,
      name: 'Observations',
      icon: 'mdi-compass',
      permission: PERMISSIONS.OBSERVATIONS_READ,
    });
  },
};

export default plugin;
