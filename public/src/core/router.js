import { createWebHistory, createRouter } from 'vue-router';
import { useAuthStore } from '../stores/auth';

const router = createRouter({
  history: createWebHistory(),
  routes: [],
});

// Plugins register their own routes at boot (see core/services/app-service.js);
// this guard applies uniformly to whatever they end up registering. A
// route with no `meta.permission` and no `meta.public` (the pre-existing
// Vuetify plugins - items, notification_channels, scrapers, observations -
// none of which set either) is treated as open to any authenticated user,
// same as before auth existed; only routes that opt into `meta.permission`
// (the new plugins) get gated on it.
router.beforeEach((to) => {
  const auth = useAuthStore();

  if (to.meta.public) {
    if (auth.isAuthenticated) {
      return { path: '/' };
    }
    return true;
  }

  if (!auth.isAuthenticated) {
    return { path: '/login', query: { redirect: to.fullPath } };
  }

  if (to.meta.permission && !auth.can(to.meta.permission)) {
    return { path: '/' };
  }

  return true;
});

export default router;
