<script setup>
import { ref, watch } from 'vue';
import app from './app';
import { version } from '../../package.json';

const drawer = ref(true);
const group = ref(null);

watch(group, () => {
  drawer.value = false;
});
</script>

<template>
  <v-app>
    <v-app-bar :elevation="2">
      <v-app-bar-nav-icon
        variant="text"
        @click.stop="drawer = !drawer"
      ></v-app-bar-nav-icon>

      <v-app-bar-title>Price monitor <span style="font-size: 12px">(v{{ version }})</span></v-app-bar-title>
      
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
      <span v-for="[_, app] in app.appService.__apps">
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
