import LoginView from './views/LoginView.vue';
import UsersListView from './views/UsersListView.vue';
import UserFormView from './views/UserFormView.vue';
import RolesListView from './views/RolesListView.vue';
import RoleFormView from './views/RoleFormView.vue';
import ApiKeysView from './views/ApiKeysView.vue';
import { PERMISSIONS } from '../../constants/permissions';
import IconUsers from '../../components/common/icons/IconUsers.vue';
import IconShield from '../../components/common/icons/IconShield.vue';
import IconKey from '../../components/common/icons/IconKey.vue';

const plugin = {
  name: 'security',
  setup(core, plugins) {
    // Not nav-visible - registered directly rather than via registerApp.
    core.router.addRoute({ path: '/login', component: LoginView, meta: { public: true } });

    core.appService.registerApp({
      route: '/users',
      component: UsersListView,
      name: 'Users',
      icon: IconUsers,
      permission: PERMISSIONS.USERS_READ,
    });
    core.router.addRoute({
      path: '/users/new',
      component: UserFormView,
      meta: { permission: PERMISSIONS.USERS_CREATE },
    });
    core.router.addRoute({
      path: '/users/:id/edit',
      component: UserFormView,
      props: true,
      meta: { permission: PERMISSIONS.USERS_UPDATE },
    });

    core.appService.registerApp({
      route: '/roles',
      component: RolesListView,
      name: 'Roles',
      icon: IconShield,
      permission: PERMISSIONS.ROLES_READ,
    });
    core.router.addRoute({
      path: '/roles/new',
      component: RoleFormView,
      meta: { permission: PERMISSIONS.ROLES_CREATE },
    });
    core.router.addRoute({
      path: '/roles/:id/edit',
      component: RoleFormView,
      props: true,
      meta: { permission: PERMISSIONS.ROLES_UPDATE },
    });

    core.appService.registerApp({
      route: '/keys',
      component: ApiKeysView,
      name: 'API Keys',
      icon: IconKey,
      permission: PERMISSIONS.API_KEY_MANAGE,
    });
  },
};

export default plugin;
