import EventsListView from './views/EventsListView.vue';
import EventFormView from './views/EventFormView.vue';
import { PERMISSIONS } from '../../constants/permissions';

const plugin = {
  name: 'events',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/events',
      component: EventsListView,
      name: 'Events',
      icon: 'mdi-history',
      permission: PERMISSIONS.EVENTS_READ,
    });
    core.router.addRoute({
      path: '/events/new',
      component: EventFormView,
      meta: { permission: PERMISSIONS.EVENTS_CREATE },
    });
  },
};

export default plugin;
