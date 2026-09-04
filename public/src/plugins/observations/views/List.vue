<script setup>
import { ref } from 'vue';
import TableItems from '../../../components/common/TableServerItems.vue';
import { APIObservations } from '../../../services/api';
import TableActionAsync from '../../../components/common/TableActionAsync.vue';

const tableHeaders = [
  { key: 'timestamp', title: 'Date' },
  { key: 'item.name', title: 'Name' },
  { key: 'url', title: 'URL' },
  { key: 'price', title: 'Price' },
  { key: 'available', title: 'Available' },
  { key: 'discount', title: 'Discount' },
  { title: 'Actions', align: 'end', key: 'actions', sortable: false },
];

const refetchTs = ref(0);

function updateRefetch() {
  refetchTs.value = refetchTs.value + 1;
}

async function handleEdit(item) {
  const { id, item: _, ...rest } = item;

  // await APIObservations.edit(id, rest)

  updateRefetch();
}

async function handleRemove(item) {
  const { id, ...rest } = item;

  await APIObservations.remove(id);

  updateRefetch();
}

const fetchData = props => {
  const { page, itemsPerPage, search, sortBy } = props;
  return APIObservations.getList({ page, itemsPerPage, search, sortBy }).then(
    ({ body: { items, total_items } }) => ({ items, total_items }),
  );
};

const initialSortBy = [{ key: 'timestamp', order: 'desc' }];
</script>

<template>
  <TableItems
    :fetch="fetchData"
    :table-headers="tableHeaders"
    title="Monitoring"
    :refetch="refetchTs"
    :sortBy="initialSortBy"
  >
    <template v-slot:item.url="{ item, field }">
      <a :href="field" target="_blank" rel="noopener noreferrer">link</a>
    </template>

    <template v-slot:item.available="{ field }">
      <span>{{ field ? '✅' : '' }}</span>
    </template>

    <template v-slot:actions="{ item, index, action }">
      <TableActionAsync
        :item="item"
        icon="mdi-pencil"
        :title="`Edit item [${item.id}]`"
        :on-confirm="handleEdit"
      >
        <template v-slot:body="{ record, action: action2 }">
          <v-card-text>
            <v-text-field
              v-model="record.price"
              density="compact"
              label="Price"
              variant="plain"
              rounded
            ></v-text-field>
            <v-text-field
              v-model="record.url"
              density="compact"
              label="URL"
              variant="plain"
              rounded
            ></v-text-field>
          </v-card-text>
        </template>
      </TableActionAsync>
      <TableActionAsync
        :item="item"
        icon="mdi-delete-outline"
        icon-color="error"
        :title="`Remove item [${item.id}]`"
        :on-confirm="handleRemove"
      >
      </TableActionAsync>
    </template>
  </TableItems>
</template>
