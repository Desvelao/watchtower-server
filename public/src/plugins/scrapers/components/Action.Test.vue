<script setup>
import ButtonDialog from '../../../components/common/ButtonDialog.vue';
import ActionTestForm from './Action.Test.Form.vue';
import { useAsyncAction } from '../../../hooks/useAction';
import * as ScraperAPI from '../api';

const props = defineProps({
  record: {
    type: Object,
    required: true,
  },
});

const action = useAsyncAction(async event => {
  event.preventDefault();
  const { id, name, urls_match, selectors, test_url } = props.record;

  const response = id
    ? await ScraperAPI.testSite(id, { test_url })
    : await ScraperAPI.testUnregistered({
        name,
        urls_match,
        selectors,
        test_url,
      });

  return response.body.data;
});

const { isRunning } = action;
</script>

<template>
  <ButtonDialog
    icon="mdi-test-tube"
    :title="`Test site [${props.record.id}]`"
    @on-confirm="() => action.run(record)"
  >
    <ActionTestForm :action="action" :record="record"></ActionTestForm>
  </ButtonDialog>
</template>
