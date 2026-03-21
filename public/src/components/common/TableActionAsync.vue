<script setup>
import { ref } from 'vue';
import ButtonDialogConfirm from '../common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../hooks/useAction';

const { onConfirm, item } = defineProps({
  item: {
    type: Object,
    required: true,
  },
  icon: {
    type: String,
    required: true,
  },
  iconColor: {
    type: String,
    required: true,
  },
  title: {
    type: String,
    required: true,
  },
  onConfirm: {
    type: Function,
    required: true,
  },
});

const record = ref({ ...item });

const action = useAsyncAction(async item => {
  await onConfirm(item);
});
const { run, isRunning } = action;
</script>

<template>
  <ButtonDialogConfirm
    :icon="icon"
    :icon-color="iconColor"
    :title="title"
    @on-confirm="() => run(record)"
    :disabled="isRunning"
  >
    <slot name="body" :record="record" :action="action"></slot>
  </ButtonDialogConfirm>
</template>
