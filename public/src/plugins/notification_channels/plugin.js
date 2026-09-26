import NotificationChannelsListView from './views/NotificationChannelsListView.vue';
import NotificationChannelFormView from './views/NotificationChannelFormView.vue';
import PoliciesListView from './views/PoliciesListView.vue';
import PolicyFormView from './views/PolicyFormView.vue';
import DeliveriesListView from './views/DeliveriesListView.vue';
import IconMail from '../../components/common/icons/IconMail.vue';
import IconFunnel from '../../components/common/icons/IconFunnel.vue';
import IconTruck from '../../components/common/icons/IconTruck.vue';
import { PERMISSIONS } from '../../constants/permissions';

const plugin = {
  name: 'notification_channels',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/notifications_channels',
      component: NotificationChannelsListView,
      name: 'Notifications',
      icon: IconMail,
      permission: PERMISSIONS.CHANNELS_READ,
    });
    core.router.addRoute({
      path: '/notifications_channels/new',
      component: NotificationChannelFormView,
      meta: { permission: PERMISSIONS.CHANNELS_CREATE },
    });
    core.router.addRoute({
      path: '/notifications_channels/:id/edit',
      component: NotificationChannelFormView,
      props: true,
      meta: { permission: PERMISSIONS.CHANNELS_UPDATE },
    });

    // Notification policies: routes fired alerts to the channels above, via
    // the same condition language rules use - see
    // server/plugins/notification_channels/services/policies.lua.
    core.appService.registerApp({
      route: '/notification_policies',
      component: PoliciesListView,
      name: 'Notification Policies',
      icon: IconFunnel,
      permission: PERMISSIONS.POLICIES_READ,
    });
    core.router.addRoute({
      path: '/notification_policies/new',
      component: PolicyFormView,
      meta: { permission: PERMISSIONS.POLICIES_CREATE },
    });
    core.router.addRoute({
      path: '/notification_policies/:id/edit',
      component: PolicyFormView,
      props: true,
      meta: { permission: PERMISSIONS.POLICIES_UPDATE },
    });

    // Read-only: one row per (alert, channel) delivery outcome the notify
    // pipeline has produced - see server/models/alert_deliveries.lua.
    core.appService.registerApp({
      route: '/notification_deliveries',
      component: DeliveriesListView,
      name: 'Notification Deliveries',
      icon: IconTruck,
      permission: PERMISSIONS.DELIVERIES_READ,
    });
  },
};

export default plugin;
