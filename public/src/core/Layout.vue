<script setup>
import { computed, ref, onMounted, onUnmounted, watch } from 'vue';
import app from './app';
import { version } from '../../package.json';
import { useAuthStore } from '../stores/auth';
import { useThemeStore } from '../stores/theme';
import { useRouter } from 'vue-router';
import IconMenu from '../components/common/icons/IconMenu.vue';
import IconClose from '../components/common/icons/IconClose.vue';
import IconSidebarCollapse from '../components/common/icons/IconSidebarCollapse.vue';
import IconSun from '../components/common/icons/IconSun.vue';
import IconMoon from '../components/common/icons/IconMoon.vue';
import IconMonitor from '../components/common/icons/IconMonitor.vue';
import IconWatchtower from '../components/common/icons/IconWatchtower.vue';

const STORAGE_KEY = 'watchtower_sidebar_collapsed';

const collapsed = ref(false);
const mobileOpen = ref(false);

onMounted(() => {
  collapsed.value = localStorage.getItem(STORAGE_KEY) === 'true';
});

watch(collapsed, (value) => {
  localStorage.setItem(STORAGE_KEY, String(value));
});

const auth = useAuthStore();
const theme = useThemeStore();
const router = useRouter();

const THEME_OPTIONS = [
  { value: 'light', label: 'Light', icon: IconSun },
  { value: 'dark', label: 'Dark', icon: IconMoon },
  { value: 'system', label: 'System', icon: IconMonitor },
];
const themeMenuOpen = ref(false);
const themeMenuRef = ref(null);
const currentThemeIcon = computed(
  () => THEME_OPTIONS.find((option) => option.value === theme.preference)?.icon || IconMoon,
);

function selectTheme(value) {
  theme.setPreference(value);
  themeMenuOpen.value = false;
}

function onDocumentClick(event) {
  if (themeMenuOpen.value && themeMenuRef.value && !themeMenuRef.value.contains(event.target)) {
    themeMenuOpen.value = false;
  }
}

function onKeydown(event) {
  if (event.key === 'Escape') {
    themeMenuOpen.value = false;
  }
}

onMounted(() => {
  document.addEventListener('mousedown', onDocumentClick);
  document.addEventListener('keydown', onKeydown);
});
onUnmounted(() => {
  document.removeEventListener('mousedown', onDocumentClick);
  document.removeEventListener('keydown', onKeydown);
});

// A registered app with no `permission` stays visible to any signed-in
// user, matching how the router guard treats an unset meta.permission -
// only apps that declare one are actually gated.
const visibleApps = computed(() =>
  [...app.appService.__apps].filter(([, item]) => !item.permission || auth.can(item.permission)),
);

function logout() {
  auth.logout();
  router.push('/login');
}
</script>

<template>
  <slot v-if="!auth.isAuthenticated"></slot>
  <div v-else class="flex h-screen bg-slate-50 dark:bg-slate-900">
    <div v-if="mobileOpen" class="fixed inset-0 z-30 bg-slate-900/40 lg:hidden" @click="mobileOpen = false"></div>

    <aside
      class="fixed inset-y-0 left-0 z-40 flex flex-col border-r border-slate-200 bg-white transition-transform duration-200 dark:border-slate-700 dark:bg-slate-800 lg:static lg:translate-x-0"
      :class="[mobileOpen ? 'translate-x-0' : '-translate-x-full', collapsed ? 'w-16' : 'w-56']"
    >
      <div class="flex h-14 shrink-0 items-center justify-end border-b border-slate-200 px-3 dark:border-slate-700">
        <button
          type="button"
          class="rounded p-1.5 text-slate-500 hover:bg-slate-100 dark:text-slate-400 dark:hover:bg-slate-700 lg:hidden"
          aria-label="Close menu"
          @click="mobileOpen = false"
        >
          <IconClose class="h-5 w-5" />
        </button>
      </div>

      <nav class="flex-1 space-y-1 overflow-y-auto p-2">
        <RouterLink
          v-for="[, item] in visibleApps"
          :key="item.route"
          :to="item.route"
          :title="collapsed ? item.name : undefined"
          active-class="bg-slate-200 font-medium text-slate-900 dark:bg-slate-700 dark:text-slate-100"
          class="flex items-center gap-3 rounded px-2.5 py-2 text-sm text-slate-700 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
          @click="mobileOpen = false"
        >
          <component :is="item.icon" class="h-5 w-5 shrink-0" />
          <span v-if="!collapsed" class="truncate">{{ item.name }}</span>
        </RouterLink>
      </nav>

      <button
        type="button"
        class="hidden shrink-0 items-center justify-center gap-2 border-t border-slate-200 py-2.5 text-slate-500 hover:bg-slate-100 dark:border-slate-700 dark:text-slate-400 dark:hover:bg-slate-700 lg:flex"
        :aria-label="collapsed ? 'Expand sidebar' : 'Collapse sidebar'"
        @click="collapsed = !collapsed"
      >
        <IconSidebarCollapse class="h-5 w-5 transition-transform" :class="collapsed ? 'rotate-180' : ''" />
      </button>
    </aside>

    <div class="flex min-w-0 flex-1 flex-col">
      <header class="flex h-14 shrink-0 items-center justify-between border-b border-slate-200 bg-white px-4 dark:border-slate-700 dark:bg-slate-800">
        <div class="flex items-center gap-3">
          <button
            type="button"
            class="rounded p-1.5 text-slate-500 hover:bg-slate-100 dark:text-slate-400 dark:hover:bg-slate-700 lg:hidden"
            aria-label="Open menu"
            @click="mobileOpen = true"
          >
            <IconMenu class="h-5 w-5" />
          </button>
          <IconWatchtower class="h-6 w-6 shrink-0" />
          <span class="text-sm font-semibold text-slate-900 dark:text-slate-100">
            Watchtower <span class="text-xs font-normal text-slate-400 dark:text-slate-500">(v{{ version }})</span>
          </span>
        </div>

        <div class="flex items-center gap-3">
          <span class="text-xs text-slate-500 dark:text-slate-400">{{ auth.username }} ({{ auth.role }})</span>
          <div ref="themeMenuRef" class="relative">
            <button
              type="button"
              aria-haspopup="menu"
              :aria-expanded="themeMenuOpen"
              title="Theme"
              class="rounded p-1.5 text-slate-600 hover:bg-slate-100 hover:text-slate-900 dark:text-slate-400 dark:hover:bg-slate-700 dark:hover:text-slate-100"
              @click="themeMenuOpen = !themeMenuOpen"
            >
              <component :is="currentThemeIcon" class="h-4 w-4" />
            </button>
            <div
              v-if="themeMenuOpen"
              role="menu"
              class="absolute right-0 z-50 mt-1 w-32 overflow-hidden rounded-lg border border-slate-200 bg-white py-1 shadow-lg dark:border-slate-700 dark:bg-slate-800"
            >
              <button
                v-for="option in THEME_OPTIONS"
                :key="option.value"
                type="button"
                role="menuitemradio"
                :aria-checked="theme.preference === option.value"
                class="flex w-full items-center gap-2 px-3 py-1.5 text-left text-sm text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
                :class="theme.preference === option.value ? 'font-medium text-slate-900 dark:text-slate-100' : ''"
                @click="selectTheme(option.value)"
              >
                <component :is="option.icon" class="h-4 w-4" />
                {{ option.label }}
              </button>
            </div>
          </div>
          <button
            type="button"
            class="rounded px-2.5 py-1.5 text-sm text-slate-600 hover:bg-slate-100 dark:text-slate-300 dark:hover:bg-slate-700"
            @click="logout"
          >
            Log out
          </button>
        </div>
      </header>

      <main class="flex-1 overflow-y-auto px-4 py-6">
        <slot></slot>
      </main>
    </div>
  </div>
</template>
