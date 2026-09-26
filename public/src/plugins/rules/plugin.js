import RulesListView from './views/RulesListView.vue';
import RuleFormView from './views/RuleFormView.vue';
import RuleTestView from './views/RuleTestView.vue';
import { PERMISSIONS } from '../../constants/permissions';
import IconScript from '../../components/common/icons/IconScript.vue';

const plugin = {
  name: 'rules',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/rules',
      component: RulesListView,
      name: 'Rules',
      icon: IconScript,
      permission: PERMISSIONS.RULES_READ,
    });
    core.router.addRoute({
      path: '/rules/new',
      component: RuleFormView,
      meta: { permission: PERMISSIONS.RULES_CREATE },
    });
    core.router.addRoute({
      path: '/rules/:id/edit',
      component: RuleFormView,
      props: true,
      meta: { permission: PERMISSIONS.RULES_UPDATE },
    });
    core.router.addRoute({
      path: '/rules/test',
      component: RuleTestView,
      meta: { permission: PERMISSIONS.RULES_READ },
    });
  },
};

export default plugin;
