<script setup>
import ButtonDialogConfirm from '../../../components/common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../../hooks/useAction';
import * as ScraperAPI from '../api';

const emits = defineEmits(['on-confirm']);

const action = useAsyncAction(async () => {
  await ScraperAPI.exportFile();
  emits('on-confirm');
});

const { isRunning } = action;
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-export"
    :iconSize="40"
    title="Export"
    @on-confirm="() => action.run()"
    :disabled="isRunning"
  >
  </ButtonDialogConfirm>
</template>
