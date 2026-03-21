<script setup>
import { ref } from 'vue';
import ButtonDialogConfirm from '../../../components/common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../../hooks/useAction';
import { APINotificationChannels } from '../../../services/api';
import NotificationChannelForm from './NotificationChannel.Form.vue';

const DEFAULT_RECORD = () => ({
  name: '',
  type: '',
  options_discord: { url: '', message: '' },
  options_webhook: { method: 'POST', url: '', headers: '', body: '' },
});

const record = ref(DEFAULT_RECORD());

const emits = defineEmits(['on-create']);

const action = useAsyncAction(async item => {
  const { name, type } = item;
  const data = {
    name,
    type,
    options: item['options_' + type],
  };
  await APINotificationChannels.create(data);
  emits('on-create');

  record.value = DEFAULT_RECORD();
});

const validForm = ref(false);

const { isRunning, run } = action;
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-plus"
    :iconSize="40"
    title="Add notification channel"
    @on-confirm="() => run(record)"
    :disabled="isRunning"
    :disabledConfirm="!validForm"
  >
    <NotificationChannelForm v-model="record" v-model:validation="validForm" />
  </ButtonDialogConfirm>
</template>
