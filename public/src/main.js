import { createApp } from 'vue';
import { createPinia } from 'pinia';
import { app } from './core';
import { useAuthStore } from './stores/auth';
import { useThemeStore } from './stores/theme';

import './assets/tailwind.css';

// Plugin system
import { PluginSystem } from './core/services/plugin-service';
import EntitiesPlugin from './plugins/entities/plugin';
import NotificationChannelsPlugin from './plugins/notification_channels/plugin';
import ObserverConfigsPlugin from './plugins/observer_configs/plugin';
import SecurityPlugin from './plugins/security/plugin';
import RulesPlugin from './plugins/rules/plugin';
import AlertingPlugin from './plugins/alerting/plugin';
import WorkersPlugin from './plugins/workers/plugin';
import SchedulerPlugin from './plugins/scheduler/plugin';
import JobsPlugin from './plugins/jobs/plugin';

// Hightlight code
import { HighCode } from 'vue-highlight-code';
import 'vue-highlight-code/dist/style.css';

const vueApp = createApp(app.view);
vueApp.use(createPinia());
vueApp.component('HighCode', HighCode);

useThemeStore().restore();

const pluginSystem = new PluginSystem();

pluginSystem
  .addPlugin(SecurityPlugin)
  .addPlugin(EntitiesPlugin)
  .addPlugin(RulesPlugin)
  .addPlugin(AlertingPlugin)
  .addPlugin(WorkersPlugin)
  .addPlugin(SchedulerPlugin)
  .addPlugin(JobsPlugin)
  .addPlugin(NotificationChannelsPlugin)
  .addPlugin(ObserverConfigsPlugin)
  .run(app);

// Awaited before mounting so the router guard (core/router.js) never sees
// an unhydrated auth store - a hard refresh on a protected route must
// resolve auth.isAuthenticated correctly on the very first navigation,
// not after a flash of the login redirect.
useAuthStore()
  .restore()
  .then(() => {
    vueApp.use(app.router);
    vueApp.mount('#app');
  });
