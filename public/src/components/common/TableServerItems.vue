<script setup>
import { ref, watch } from 'vue';
import { useAsyncAction } from '../../hooks/useAction';
import { get } from 'lodash';

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
  sortBy: {
    type: Array,
    default: [],
  },
});

const tableHeadersNoActions = props.tableHeaders.filter(
  ({ key }) => key !== 'actions',
);

const action = useAsyncAction(props.fetch, {
  data: { items: [], total_items: 0 },
});

const { isRunning, data, error, run } = action;

const search = ref('');
const searchDebounced = ref('');

// Custom debounce function
const debounce = (func, delay) => {
  let timeout;
  return (...args) => {
    clearTimeout(timeout);
    timeout = setTimeout(() => func(...args), delay);
  };
};

// Debounced setter
const updateDebounced = debounce(val => {
  searchDebounced.value = val;
}, 500);

// Watch for changes and debounce
watch(search, newVal => {
  updateDebounced(newVal);
});

const page = ref(1);
const itemsPerPage = ref(10);
const sortBy = ref(props.sortBy);

function refresh() {
  action.run({
    page: page.value,
    itemsPerPage: itemsPerPage.value,
    sortBy: sortBy.value,
    search: search.value,
  });
}

// Watch for changes in props.myProp
watch(
  () => props.refetch,
  (newValue, oldValue) => {
    page.value = 1;
    refresh();
  },
);

function updatePage(newValue) {
  page.value = newValue;
}

function updateItemsPerPage(newValue) {
  itemsPerPage.value = newValue;
}

function updateSortBy(newValue) {
  sortBy.value = newValue;
}
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
        <v-icon-btn
          icon="mdi-refresh"
          size="40"
          color="primary"
          title="Refresh"
          @click="refresh"
        >
          <v-icon :size="(40 * 2) / 3"></v-icon>
        </v-icon-btn>
      </div>
    </div>

    <div>
      <v-text-field
        v-model="search"
        placeholder="Search"
        @clearable="true"
        @keyup.enter="console.log"
      ></v-text-field>
    </div>

    <v-sheet border>
      <v-data-table-server
        :items-per-page="itemsPerPage"
        :headers="tableHeaders"
        :items="data.items"
        :items-length="data.total_items"
        :loading="isRunning"
        :search="searchDebounced"
        item-value="id"
        :page="page"
        v-model:sort-by="sortBy"
        @update:options="run"
        @update:page="updatePage"
        @update:itemsPerPage="updateItemsPerPage"
        @update:sortBy="updateSortBy"
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
      </v-data-table-server>
    </v-sheet>
  </v-container>
</template>
