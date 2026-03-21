<script setup>
import { ref } from 'vue';
import ButtonDialogConfirm from '../common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../hooks/useAction';
import { APIProducts } from '../../services/api';
import ItemForm from './Item.Form.vue';

const action = useAsyncAction(async item => {
  await APIProducts.create(item);
  emits('on-create');

  record.value = DEFAULT_RECORD();
});

const { isRunning, run } = action;

const DEFAULT_RECORD = () => ({ name: '', url: '', enabled: true });

const record = ref(DEFAULT_RECORD());
const validForm = ref(false);

const emits = defineEmits(['on-create']);
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-plus"
    :iconSize="40"
    title="Add item"
    @on-confirm="() => run(record)"
    :disabled="isRunning"
    :disabledConfirm="!validForm"
  >
    <v-card-text>
      <ItemForm v-model="record" v-model:validation="validForm" />
    </v-card-text>
  </ButtonDialogConfirm>
</template>
