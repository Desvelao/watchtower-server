import { setServices } from './services/services';
import Component from './views/List.vue';

const plugin = {
  name: 'items',
  setup(core, plugins) {
    core.router.addRoute({ path: '/', component: Component });
    core.appService.registerApp({
      route: '/items',
      component: Component,
      name: 'Items',
      icon: 'mdi-table',
    });
    setServices(core);
  },
};

export default plugin;
