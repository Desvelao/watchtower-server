import { createWebHistory, createRouter } from 'vue-router';
import { useAuthStore } from '../stores/auth';

const router = createRouter({
  history: createWebHistory(),
  routes: [],
});

// Plugins register their own routes at boot (see core/services/app-service.js);
// this guard applies uniformly to whatever they end up registering. A route
// with no `meta.permission` and no `meta.public` is treated as open to any
// authenticated user; only routes that opt into `meta.permission` get gated
// on it.
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
    // '/' itself now carries a permission (see entities/plugin.js), so
    // redirecting a denied navigation there unconditionally would recurse
    // forever for a user who also lacks that permission. Cancel instead of
    // redirecting when '/' is already the (denied) target.
    return to.path === '/' ? false : { path: '/' };
  }

  return true;
});

export default router;
