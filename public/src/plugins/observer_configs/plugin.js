import ObserverConfigsListView from './views/ObserverConfigsListView.vue';
import ObserverConfigFormView from './views/ObserverConfigFormView.vue';
import ObserverConfigsTestAllView from './views/ObserverConfigsTestAllView.vue';
import IconRadar from '../../components/common/icons/IconRadar.vue';
import { PERMISSIONS } from '../../constants/permissions';

const plugin = {
  name: 'observer_configs',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/observer_configs',
      component: ObserverConfigsListView,
      name: 'Observer Configs',
      icon: IconRadar,
      permission: PERMISSIONS.OBSERVER_CONFIGS_READ,
    });
    core.router.addRoute({
      path: '/observer_configs/new',
      component: ObserverConfigFormView,
      meta: { permission: PERMISSIONS.OBSERVER_CONFIGS_CREATE },
    });
    core.router.addRoute({
      path: '/observer_configs/:id/edit',
      component: ObserverConfigFormView,
      props: true,
      meta: { permission: PERMISSIONS.OBSERVER_CONFIGS_UPDATE },
    });
    core.router.addRoute({
      path: '/observer_configs/test',
      component: ObserverConfigsTestAllView,
      meta: { permission: PERMISSIONS.OBSERVER_CONFIGS_CREATE },
    });
  },
};

export default plugin;
