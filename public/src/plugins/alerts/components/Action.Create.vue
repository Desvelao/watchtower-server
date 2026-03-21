<script setup>
import { ref } from 'vue';
import ButtonDialogConfirm from '../../../components/common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../../hooks/useAction';
import { APIAlerts } from '../../../services/api';
import AlertForm from './Alert.Form.vue';

const action = useAsyncAction(async item => {
  return await APIAlerts.create(item);
});

const DEFAULT_RECORD = () => ({
  name: '',
  enabled: true,
  alert: null,
  channels: [],
  trigger_on_price: '',
  trigger_on_discount: false,
  trigger_on_available: false,
});

const record = ref(DEFAULT_RECORD());

const emits = defineEmits(['on-create']);

async function handleOnConfirm(record) {
  const {
    name,
    enabled,
    channels,
    trigger_on_price,
    trigger_on_discount,
    trigger_on_available,
    alert,
  } = record;
  const data = {
    name,
    enabled,
    item_id: alert.value,
    trigger_on_price,
    trigger_on_discount,
    trigger_on_available,
    channels: channels.map(({ value }) => value),
  };
  await action.run(data);
  emits('on-create');

  record.value = { ...DEFAULT_RECORD() };
}

const validForm = ref(false);
const { isRunning } = action;
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-plus"
    :iconSize="40"
    title="Add alert"
    @on-confirm="() => handleOnConfirm(record)"
    :disabled="isRunning"
    :disabledConfirm="!validForm"
  >
    <v-card-text>
      <AlertForm v-model="record" v-model:validation="validForm" />
    </v-card-text>
  </ButtonDialogConfirm>
</template>
