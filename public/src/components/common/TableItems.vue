<script setup>
import { onMounted, watch } from "vue";
import { useAsyncAction } from "../../hooks/useAction";
import { get } from "lodash";

const props = defineProps({
  fetch: {
    type: Function,
    required: true,
  },
  tableHeaders: {
    type: Array,
    required: true,
  },
  title: {
    type: String,
    required: true,
  },
  refetch: {
    type: Number,
    default: 0,
  },
});

const tableHeadersNoActions = props.tableHeaders.filter(
  ({ key }) => key !== "actions",
);

const action = useAsyncAction(props.fetch, { data: [] });

const { isRunning, data, error, run } = action;

onMounted(async () => {
  try {
    await run();
  } catch (error) {
    console.log(error);
  }
});

// Watch for changes in props.myProp
watch(
  () => props.refetch,
  (newValue, oldValue) => {
    action.run();
  },
);
</script>

<template>
  <!-- https://vuetifyjs.com/en/components/icon-buttons/#datatable-actions -->
  <v-container>
    <div class="d-flex align-center">
      <div style="width: 80%">
        <div class="d-flex justify-center">
          <h1>{{ title }}</h1>
        </div>
      </div>
      <div style="width: 20%" class="d-flex justify-end">
        <slot name="external.actions"></slot>
        <v-btn color="primary" @click="action.run">Refresh</v-btn>
      </div>
    </div>

    <v-sheet border>
      <v-data-table
        :headers="tableHeaders"
        :items="data"
        :loading="isRunning"
        :items-per-page="10"
      >
        <template
          v-for="slotName in tableHeadersNoActions"
          :key="slotName"
          v-slot:[`item.${slotName.key}`]="{ item, index }"
        >
          <!-- The wrapped slot passes along whatever is provided by the caller -->
          <slot
            v-if="slotName.key !== 'actions'"
            :name="`item.${slotName.key}`"
            :item="item"
            :field="get(item, slotName.key)"
            :index="index"
            :action="action"
          >
            {{ get(item, slotName.key) }}
          </slot>
        </template>

        <template v-slot:item.actions="{ item, index }">
          <div class="d-flex ga-2 justify-end">
            <slot
              name="actions"
              :item="item"
              :index="index"
              :action="action"
            ></slot>
          </div>
        </template>
      </v-data-table>
    </v-sheet>
  </v-container>
</template>
