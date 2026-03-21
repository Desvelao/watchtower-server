<script setup>
import { shallowRef, unref } from 'vue';

const dialog = shallowRef(false);

const props = defineProps({
  title: {
    type: String,
    default: 'Dialog',
  },
  icon: {
    type: String,
    required: true,
  },
  iconSize: {
    type: Number,
    default: 24,
  },
  iconColor: {
    type: String,
    default: null,
  },
  cancelLabel: {
    type: String,
    default: 'Cancel',
  },
  disabled: {
    type: Boolean,
    default: false,
  },
  onLeave: {
    type: Function,
  },
  maxWidth: {
    type: Number,
    default: 450,
  },
});

const emits = defineEmits(['on-confirm', 'click']);

function handleClick() {
  dialog.value = true;
  emits('click');
}

function handleAfterLeave() {
  props.onLeave?.();
}
</script>

<template>
  <v-icon-btn
    :icon="icon"
    :size="iconSize"
    :color="iconColor"
    variant="plain"
    @click="handleClick()"
    :disabled="unref(disabled)"
  >
    <v-icon :size="(iconSize * 2) / 3"></v-icon>
  </v-icon-btn>

  <v-dialog
    v-model="dialog"
    :max-width="maxWidth"
    @after-leave="handleAfterLeave"
  >
    <v-card density="compact" :title="title">
      <v-divider></v-divider>
      <slot></slot>
      <v-divider></v-divider>
    </v-card>
  </v-dialog>
</template>
