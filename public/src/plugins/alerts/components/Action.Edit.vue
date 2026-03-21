<script setup>
import { ref } from 'vue';
import ButtonDialogConfirm from '../../../components/common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../../hooks/useAction';
import { APIAlerts } from '../../../services/api';
import AlertForm from './Alert.Form.vue';

const action = useAsyncAction(async item => {
  const { id, ...rest } = item;
  return await APIAlerts.edit(id, rest);
});

const props = defineProps({
  record: {
    type: Object,
    required: true,
  },
});

const record = ref({
  name: props.record.name,
  enabled: props.record.enabled,
  channels: props.record.channels.map(({ id, name }) => ({
    title: name,
    value: id,
  })),
  trigger_on_price: props.record.trigger_on_price,
  trigger_on_discount: props.record.trigger_on_discount,
  trigger_on_available: props.record.trigger_on_available,
  alert: { title: props.record.item.name, value: props.record.item.id },
});

const emits = defineEmits(['on-edit']);

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
    id: props.record.id,
    name,
    enabled,
    item_id: alert.value,
    trigger_on_price,
    trigger_on_discount,
    trigger_on_available,
    channels: channels.map(({ value }) => value),
  };
  await action.run(data);
  emits('on-edit');
}

const validForm = ref(false);
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-pencil"
    :title="`Edit item [${props.record.id}]`"
    @on-confirm="() => handleOnConfirm(record)"
    :disabled="action.isRunning"
    :disabledConfirm="!validForm"
  >
    <AlertForm v-model="record" v-model:validation="validForm" />
  </ButtonDialogConfirm>
</template>
