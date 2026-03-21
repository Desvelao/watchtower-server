<script setup>
import { ref } from 'vue';
import ButtonDialogConfirm from '../../../components/common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../../hooks/useAction';
import { APINotificationChannels } from '../../../services/api';
import NotificationChannelForm from './NotificationChannel.Form.vue';

const props = defineProps({
  record: {
    type: Object,
    required: true,
  },
});

const emits = defineEmits(['on-edit']);

const record = ref({
  name: props.record.name,
  type: props.record.type,
  ...(props.record.type === 'discord'
    ? {
        options_discord: {
          url: props.record.options.url,
          message: props.record.options.message,
        },
      }
    : {}),
});
const validForm = ref(false);

const action = useAsyncAction(async item => {
  const data = {
    name: item.name,
    type: item.type,
    ...(item.type === 'discord'
      ? {
          options: {
            url: item.options_discord.url,
            message: item.options_discord.message,
          },
        }
      : {}),
  };
  await APINotificationChannels.edit(props.record.id, data);
  emits('on-edit');
});
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-pencil"
    :title="`Edit notification channel [${props.record.id}]`"
    @on-confirm="() => action.run(record)"
    :disabled="action.isRunning"
    :disabledConfirm="!validForm"
  >
    <NotificationChannelForm v-model="record" v-model:validation="validForm" />
  </ButtonDialogConfirm>
</template>
