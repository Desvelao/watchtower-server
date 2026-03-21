import { setServices } from './services';
import Component from './views/List.vue';
import './styles/index.css';

const plugin = {
  name: 'scrapers',
  setup(core, plugins) {
    core.appService.registerApp({
      route: '/scrapers/remote_scraper',
      component: Component,
      name: 'scp:remote (Lua)',
      icon: 'mdi-search-web',
    });
    setServices(core);
  },
};

export default plugin;
