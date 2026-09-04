import { createApp } from 'vue';
import { createPinia } from 'pinia';
import { app } from './core';
import { useAuthStore } from './stores/auth';
import { useThemeStore } from './stores/theme';

// Vuetify
import 'vuetify/styles';
import { createVuetify } from 'vuetify';
import * as components from 'vuetify/components';
import * as directives from 'vuetify/directives';

// Material Design Styles
import '@mdi/font/css/materialdesignicons.css'; // Ensure you are using css-loader
import { aliases, mdi } from 'vuetify/iconsets/mdi';

// Vuetify Labs
import { VIconBtn } from 'vuetify/labs/VIconBtn';

// Tailwind (the new Pinia + Tailwind plugins: security, rules, events,
// monitors, jobs, alerting - see assets/tailwind.css's header comment)
import './assets/tailwind.css';

// Plugin system
import { PluginSystem } from './core/services/plugin-service';
import ItemsPlugin from './plugins/items/plugin';
import ObservationsPlugin from './plugins/observations/plugin';
import NotificationChannelsPlugin from './plugins/notification_channels/plugin';
import ScraperPlugin from './plugins/scrapers/plugin';
import SecurityPlugin from './plugins/security/plugin';
import RulesPlugin from './plugins/rules/plugin';
import EventsPlugin from './plugins/events/plugin';
import AlertingPlugin from './plugins/alerting/plugin';
import MonitorsPlugin from './plugins/monitors/plugin';
import JobsPlugin from './plugins/jobs/plugin';

// Hightlight code
import { HighCode } from 'vue-highlight-code';
import 'vue-highlight-code/dist/style.css';

const vuetify = createVuetify({
  components: {
    ...components,
    VIconBtn,
    HighCode,
  },
  directives,
  icons: {
    defaultSet: 'mdi',
    aliases,
    sets: {
      mdi,
    },
  },
});

const vueApp = createApp(app.view);
vueApp.use(createPinia());
vueApp.use(vuetify);

useThemeStore().restore();

const pluginSystem = new PluginSystem();

pluginSystem
  .addPlugin(SecurityPlugin)
  .addPlugin(ItemsPlugin)
  .addPlugin(RulesPlugin)
  .addPlugin(EventsPlugin)
  .addPlugin(AlertingPlugin)
  .addPlugin(ObservationsPlugin)
  .addPlugin(MonitorsPlugin)
  .addPlugin(JobsPlugin)
  .addPlugin(NotificationChannelsPlugin)
  .addPlugin(ScraperPlugin)
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
