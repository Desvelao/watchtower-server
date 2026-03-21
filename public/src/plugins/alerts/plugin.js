import Component from './views/List.vue';

const plugin = {
  name: 'alerts',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/alerts',
      component: Component,
      name: 'Alerting',
      icon: 'mdi-bell-outline',
    });
  },
};

export default plugin;
