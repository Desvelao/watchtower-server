import Component from './views/List.vue';

const plugin = {
  name: 'notification_channels',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/notifications_channels',
      component: Component,
      name: 'Notifications',
      icon: 'mdi-email-outline',
    });
  },
};

export default plugin;
