<script setup>
import { ref } from 'vue';
import ButtonDialogConfirm from '../../../components/common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../../hooks/useAction';
import * as ScraperAPI from '../api';
import SiteForm from './Site.Form.vue';
import { toRawObject } from '../utils';

const DEFAULT_RECORD = () => ({
  name: '',
  urls_match: [''],
  fields: Object.fromEntries(
    ['price', 'discount', 'available'].map(key => [
      key,
      {
        selector: [''],
        transform: '',
        validate: '',
      },
    ]),
  ),
  urls_test: [''],
  test_url: '',
});

const record = ref(DEFAULT_RECORD());

const emits = defineEmits(['on-create']);

const action = useAsyncAction(async item => {
  const itemUnRef = toRawObject(item);
  const { name, urls_match, fields, urls_test } = itemUnRef;
  const data = {
    name,
    urls_match,
    fields,
    urls_test,
  };
  await ScraperAPI.create(data);
  emits('on-create');
  record.value = DEFAULT_RECORD();
});

const validForm = ref(false);

const { isRunning } = action;
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-plus"
    :iconSize="40"
    title="Add site"
    @on-confirm="() => action.run(record)"
    :disabled="isRunning"
    :disabledConfirm="!validForm"
    :max-width="1000"
  >
    <SiteForm v-model="record" v-model:validation="validForm" />
  </ButtonDialogConfirm>
</template>
