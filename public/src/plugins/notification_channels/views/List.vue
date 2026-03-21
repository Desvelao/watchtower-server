<script setup>
import { ref } from 'vue';
import TableItems from '../../../components/common/TableServerItems.vue';
import { APINotificationChannels } from '../../../services/api';
import TableActionAsync from '../../../components/common/TableActionAsync.vue';
import ButtonActionCreate from '../components/Action.Create.vue';
import ButtonActionEdit from '../components/Action.Edit.vue';
import NCActionInfo from '../components/Action.Info.vue';
import Dashboard from '../../../components/common/Dashboard.vue';
import DashboardItem from '../../../components/common/Dashboard.Item.vue';
import VisKPI from '../../../components/common/Vis.KPI.vue';

const tableHeaders = [
  { key: 'id', title: 'ID' },
  { key: 'name', title: 'Name' },
  { key: 'type', title: 'Type' },
  { title: 'Actions', align: 'end', key: 'actions', sortable: false },
];

const refetchTs = ref(0);

function updateRefetch() {
  refetchTs.value = refetchTs.value + 1;
}

async function handleRemove(item) {
  const { id, ...rest } = item;

  await APINotificationChannels.remove(id);

  updateRefetch();
}

const fetchData = (props = {}) => {
  const { page, itemsPerPage, search, sortBy } = props;
  return APINotificationChannels.getList({
    page,
    itemsPerPage,
    search,
    sortBy,
  }).then(({ body: { items, total_items } }) => ({ items, total_items }));
};
const initialSortBy = [{ key: 'id', order: 'asc' }];

function getItemCount() {
  return APINotificationChannels.getList({ itemsPerPage: 1 }).then(
    ({ body: { total_items } }) => total_items,
  );
}
</script>

<template>
  <Dashboard>
    <DashboardItem :span="4">
      <VisKPI
        :fetch="getItemCount"
        label="Total notifications"
        :refetch="refetchTs"
      ></VisKPI>
    </DashboardItem>
  </Dashboard>
  <TableItems
    :fetch="fetchData"
    :table-headers="tableHeaders"
    title="Notifications"
    :refetch="refetchTs"
    :sortBy="initialSortBy"
  >
    <template v-slot:item.name="{ field, item }">
      <NCActionInfo :channel="item"></NCActionInfo>
    </template>

    <template v-slot:external.actions="">
      <ButtonActionCreate @on-create="updateRefetch"></ButtonActionCreate>
    </template>

    <template v-slot:actions="{ item }">
      <ButtonActionEdit
        :record="item"
        @on-edit="updateRefetch"
      ></ButtonActionEdit>
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
