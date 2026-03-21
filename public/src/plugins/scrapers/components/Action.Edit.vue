<script setup>
import { ref } from 'vue';
import ButtonDialogConfirm from '../../../components/common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../../hooks/useAction';
import SiteForm from './Site.Form.vue';
import { toRawObject } from '../utils';
import * as ScraperAPI from '../api';

const props = defineProps({
  record: {
    type: Object,
    required: true,
  },
});

const emits = defineEmits(['on-edit']);

const record = ref({
  name: props.record.name,
  urls_match: toRawObject(props.record.urls_match),
  fields: toRawObject(props.record.fields),
  urls_test: toRawObject(props.record.urls_test),
});
const validForm = ref(false);

const action = useAsyncAction(async item => {
  const data = toRawObject(item);
  await ScraperAPI.edit(props.record.id, data);
  emits('on-edit');
});

const { isRunning } = action;
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-pencil"
    :title="`Edit site [${props.record.id}]`"
    @on-confirm="() => action.run(record)"
    :disabled="isRunning"
    :disabledConfirm="!validForm"
    :maxWidth="1000"
  >
    <SiteForm v-model="record" v-model:validation="validForm" />
  </ButtonDialogConfirm>
</template>
