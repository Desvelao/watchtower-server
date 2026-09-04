<script setup>
import { computed, ref, watch } from 'vue';
import app from './app';
import { version } from '../../package.json';
import { useAuthStore } from '../stores/auth';
import { useRouter } from 'vue-router';

const drawer = ref(true);
const group = ref(null);

watch(group, () => {
  drawer.value = false;
});

const auth = useAuthStore();
const router = useRouter();

// A registered app with no `permission` (every pre-existing Vuetify
// plugin - items, notification_channels, scrapers, observations) stays
// visible to any signed-in user, matching how the router guard treats an
// unset meta.permission - only apps that declare one are actually gated.
const visibleApps = computed(() =>
  [...app.appService.__apps].filter(([, item]) => !item.permission || auth.can(item.permission)),
);

function logout() {
  auth.logout();
  router.push('/login');
}
</script>

<template>
  <v-app>
    <v-app-bar :elevation="2">
      <v-app-bar-nav-icon
        variant="text"
        @click.stop="drawer = !drawer"
      ></v-app-bar-nav-icon>

      <v-app-bar-title>Price monitor <span style="font-size: 12px">(v{{ version }})</span></v-app-bar-title>

      <template v-if="auth.isAuthenticated" #append>
        <span class="mr-3 text-caption">{{ auth.username }} ({{ auth.role }})</span>
        <v-btn variant="text" @click="logout">Log out</v-btn>
      </template>
    </v-app-bar>
    <v-navigation-drawer
      v-model="drawer"
      :location="$vuetify.display.mobile ? 'bottom' : undefined"
      rail
      expand-on-hover
      :style="
        drawer && $vuetify.display.mobile
          ? 'height: 10vh;min-height:200px'
          : undefined
      "
    >
      <span v-for="[_, app] in visibleApps" :key="app.route">
        <v-list-item
          :prepend-icon="app.icon"
          :title="app.name"
          :to="app.route"
        ></v-list-item>
      </span>
    </v-navigation-drawer>
    <v-main>
      <slot></slot>
    </v-main>
  </v-app>
</template>
