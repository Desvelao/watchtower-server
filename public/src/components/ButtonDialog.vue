<script setup>
import { shallowRef } from 'vue';

const dialog = shallowRef(false);

defineProps({
  title: {
    type: String,
    default: 'Dialog',
  },
  icon: {
    type: String,
    required: true,
  },
  item: Object, // Optional: full item data
});

const closeDialog = () => (dialog.value = false);

const emits = defineEmits(['click']);

function handleClick() {
  dialog.value = true;
  emits('click', { close: closeDialog });
}
</script>

<template>
  <v-icon-btn :icon="icon" size="24" variant="plain" @click="handleClick()">
    <v-icon size="16"></v-icon>
  </v-icon-btn>

  <!-- @after-leave="onAfterLeave" -->
  <v-dialog v-model="dialog" :max-width="450">
    <v-card density="compact" :title="title">
      <v-divider></v-divider>
      <slot></slot>
    </v-card>
  </v-dialog>
</template>
