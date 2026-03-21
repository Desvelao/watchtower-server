<script setup>
import { ref } from 'vue';
import ButtonDialog from '../../../components/common/ButtonDialog.vue';
import ActionTestForm from './Action.Test.Form.vue';
import { useAsyncAction } from '../../../hooks/useAction';
import * as ScraperAPI from '../api';

const record = ref({
  test_url: '',
});

const action = useAsyncAction(async event => {
  event.preventDefault();
  const { test_url } = record.value;
  const response = await ScraperAPI.testAllSites({ test_url });
  return response.body.data;
});

const { isRunning } = action;
</script>

<template>
  <ButtonDialog
    icon="mdi-test-tube"
    title="Test URLs"
    :iconSize="40"
    @on-confirm="() => action.run(record)"
    :disabled="isRunning"
  >
    <ActionTestForm :action="action" :record="record"></ActionTestForm>
  </ButtonDialog>
</template>
