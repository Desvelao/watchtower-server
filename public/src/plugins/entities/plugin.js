import ObservableTypesListView from './views/ObservableTypesListView.vue';
import ObservableTypeFormView from './views/ObservableTypeFormView.vue';
import ObservablesListView from './views/ObservablesListView.vue';
import ObservableFormView from './views/ObservableFormView.vue';
import ObservationsListView from './views/ObservationsListView.vue';
import IconLayers from '../../components/common/icons/IconLayers.vue';
import IconBox from '../../components/common/icons/IconBox.vue';
import IconBinoculars from '../../components/common/icons/IconBinoculars.vue';
import { PERMISSIONS } from '../../constants/permissions';

const plugin = {
  name: 'entities',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/observable-types',
      component: ObservableTypesListView,
      name: 'Observable Types',
      icon: IconLayers,
      permission: PERMISSIONS.OBSERVABLE_TYPES_READ,
    });
    core.router.addRoute({
      path: '/observable-types/new',
      component: ObservableTypeFormView,
      meta: { permission: PERMISSIONS.OBSERVABLE_TYPES_CREATE },
    });
    core.router.addRoute({
      path: '/observable-types/:id/edit',
      component: ObservableTypeFormView,
      props: true,
      meta: { permission: PERMISSIONS.OBSERVABLE_TYPES_UPDATE },
    });

    // Preserves the previous items plugin's root-path alias.
    core.router.addRoute({
      path: '/',
      component: ObservablesListView,
      meta: { permission: PERMISSIONS.OBSERVABLES_READ },
    });
    core.appService.registerApp({
      route: '/observables',
      component: ObservablesListView,
      name: 'Observables',
      icon: IconBox,
      permission: PERMISSIONS.OBSERVABLES_READ,
    });
    core.router.addRoute({
      path: '/observables/new',
      component: ObservableFormView,
      meta: { permission: PERMISSIONS.OBSERVABLES_CREATE },
    });
    core.router.addRoute({
      path: '/observables/:id/edit',
      component: ObservableFormView,
      props: true,
      meta: { permission: PERMISSIONS.OBSERVABLES_UPDATE },
    });

    core.appService.registerApp({
      route: '/observations',
      component: ObservationsListView,
      name: 'Observations',
      icon: IconBinoculars,
      permission: PERMISSIONS.OBSERVATIONS_READ,
    });
  },
};

export default plugin;
