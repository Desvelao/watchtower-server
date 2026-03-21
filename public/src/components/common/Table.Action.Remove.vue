<script setup>
import ButtonDialogConfirm from "../common/ButtonDialogConfirm.vue";
import { useAsyncAction } from "../../hooks/useAction";
import { APIProducts } from "../../services/api";

defineProps({
  item: {
    type: Object,
    required: true,
  },
});

const emits = defineEmits("on-remove");

const action = useAsyncAction(async (item) => {
  await APIProducts.remove(item.id);
  emits("on-remove", 1);
});
</script>

<template>
  <ButtonDialogConfirm
    icon="mdi-delete-outline"
    :title="`Remove item: ${item.name} [${item.id}]?`"
    @on-confirm="() => action.run(item)"
    :disabled="action.isRunning"
    icon-color="error"
  >
  </ButtonDialogConfirm>
</template>
