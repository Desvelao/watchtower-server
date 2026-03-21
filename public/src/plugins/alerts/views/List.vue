<script setup>
import { ref } from 'vue';
import TableItems from '../../../components/common/TableServerItems.vue';
import { APIAlerts } from '../../../services/api';
import TableActionAsync from '../../../components/common/TableActionAsync.vue';
import ButtonActionCreate from '../components/Action.Create.vue';
import ButtonActionEdit from '../components/Action.Edit.vue';
import NCActionInfo from '../../notification_channels/components/Action.Info.vue';
import IActionInfo from '../../../components/products/Action.Info.vue';
import Dashboard from '../../../components/common/Dashboard.vue';
import DashboardItem from '../../../components/common/Dashboard.Item.vue';
import VisKPI from '../../../components/common/Vis.KPI.vue';

const tableHeaders = [
  { key: 'name', title: 'Name' },
  { key: 'enabled', title: 'Enabled' },
  { key: 'item.name', title: 'Item', sortable: false },
  { key: 'channels', title: 'Channels', sortable: false },
  { key: 'trigger_on_price', title: 'Trigger:price' },
  { key: 'trigger_on_discount', title: 'Trigger:discount' },
  { key: 'trigger_on_available', title: 'Trigger:available' },
  { title: 'Actions', align: 'end', key: 'actions', sortable: false },
];

const refetchTs = ref(0);

function updateRefetch() {
  refetchTs.value = refetchTs.value + 1;
}

async function handleRemove(item) {
  const { id, ...rest } = item;

  await APIAlerts.remove(id);

  updateRefetch();
}

const fetchData = props => {
  const { page, itemsPerPage, search, sortBy } = props;
  return APIAlerts.getList({ page, itemsPerPage, search, sortBy }).then(
    ({ body: { items, total_items } }) => ({ items, total_items }),
  );
};
const initialSortBy = [{ key: 'id', order: 'asc' }];

function getItemCount() {
  return APIAlerts.getList({ itemsPerPage: 1 }).then(
    ({ body: { total_items } }) => total_items,
  );
}
</script>

<template>
  <Dashboard>
    <DashboardItem :span="4">
      <VisKPI
        :fetch="getItemCount"
        label="Total alerts"
        :refetch="refetchTs"
      ></VisKPI>
    </DashboardItem>
  </Dashboard>
  <TableItems
    :fetch="fetchData"
    :table-headers="tableHeaders"
    title="Alerting"
    :refetch="refetchTs"
    :sortBy="initialSortBy"
  >
    <template v-slot:external.actions="">
      <ButtonActionCreate @on-create="updateRefetch"></ButtonActionCreate>
    </template>

    <template v-slot:item.enabled="{ field }">
      <span>{{ field ? '✅' : '' }}</span>
    </template>

    <template v-slot:item.trigger_on_discount="{ field }">
      <span>{{ field ? '✅' : '' }}</span>
    </template>

    <template v-slot:item.trigger_on_available="{ field }">
      <span>{{ field ? '✅' : '' }}</span>
    </template>

    <template v-slot:item.item="{ field, item }">
      <IActionInfo :item="item"></IActionInfo>
    </template>

    <template v-slot:item.channels="{ field }">
      <span v-for="channel in field">
        <NCActionInfo :channel="channel"></NCActionInfo>
      </span>
    </template>

    <template v-slot:actions="{ item, index, action }">
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
