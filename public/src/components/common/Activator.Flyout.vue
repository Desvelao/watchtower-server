<script setup>
import { ref } from 'vue';
import Flyout from './Flyout.vue';
defineProps({
  title: {
    type: String,
  },
});

const ifFlyoutVisible = ref(false);

function open() {
  ifFlyoutVisible.value = true;
}

function toggle() {
  ifFlyoutVisible.value = !ifFlyoutVisible.value;
}

function close() {
  ifFlyoutVisible.value = false;
}
</script>

<template>
  <div>
    <!-- The transition adds a slide animation -->
    <slot name="activator" :open="open" :toggle="toggle" :close="close"></slot>
    <Flyout v-if="ifFlyoutVisible" :close="close">
      <template v-slot:title="{ close }">
        <slot name="title" :close="close"></slot>
      </template>
      <template v-slot:body="{ close }">
        <slot name="body" :close="close"></slot>
      </template>
    </Flyout>
  </div>
</template>
