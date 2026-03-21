import { createApp } from 'vue';
import { app } from './core';

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

// Plugin system
import { PluginSystem } from './core/services/plugin-service';
import ItemsPlugin from './plugins/items/plugin';
import AlertingPlugin from './plugins/alerts/plugin';
import MonitoringPlugin from './plugins/monitoring/plugin';
import NotificationChannelsPlugin from './plugins/notification_channels/plugin';
import ScraperPlugin from './plugins/scrapers/plugin';

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

const pluginSystem = new PluginSystem();

pluginSystem
  .addPlugin(ItemsPlugin)
  .addPlugin(AlertingPlugin)
  .addPlugin(NotificationChannelsPlugin)
  .addPlugin(MonitoringPlugin)
  .addPlugin(ScraperPlugin)
  .run(app);

createApp(app.view).use(vuetify).use(app.router).mount('#app');
