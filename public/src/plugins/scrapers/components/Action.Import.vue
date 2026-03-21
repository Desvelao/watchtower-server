<script setup>
import ButtonDialogConfirm from '../../../components/common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../../hooks/useAction';
import * as ScraperAPI from '../api';

const emits = defineEmits(['on-confirm']);

const action = useAsyncAction(async () => {
  const fileInput = document.getElementById('import_file');
  const file = fileInput.files[0];

  await ScraperAPI.importFile(file);
  emits('on-confirm');
});

const { isRunning } = action;
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-import"
    :iconSize="40"
    title="Import"
    @on-confirm="() => action.run()"
    :disabled="isRunning"
  >
    <v-container>
      <v-file-input
        label="File input"
        name="file"
        id="import_file"
      ></v-file-input>
    </v-container>
  </ButtonDialogConfirm>
</template>
