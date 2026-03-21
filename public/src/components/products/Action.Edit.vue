<script setup>
import { ref } from 'vue';
import ButtonDialogConfirm from '../common/ButtonDialogConfirm.vue';
import { useAsyncAction } from '../../hooks/useAction';
import { APIProducts } from '../../services/api';
import ItemForm from './Item.Form.vue';

const props = defineProps({
  record: {
    type: Object,
    required: true,
  },
});

const record = ref({ ...props.record });

const emits = defineEmits('on-edit');

const action = useAsyncAction(async item => {
  const { id, ...rest } = item;

  await APIProducts.edit(id, { ...rest });
  emits('on-edit');
});

const { isRunning, run } = action;
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-pencil"
    :title="`Edit item ${props.record.name} [${props.record.id}]`"
    @on-confirm="() => run(record)"
    :disabled="isRunning"
  >
    <v-card-text>
      <ItemForm v-model="record" v-model:validation="validForm" />
    </v-card-text>
  </ButtonDialogConfirm>
</template>
