import Component from './views/List.vue';

const plugin = {
  name: 'monitoring',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/monitors',
      component: Component,
      name: 'Monitoring',
      icon: 'mdi-compass',
    });
  },
};

export default plugin;
