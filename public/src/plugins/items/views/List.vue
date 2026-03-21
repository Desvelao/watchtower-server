<script setup>
import { ref } from 'vue';
import TableItems from '../../../components/common/TableServerItems.vue';
import { APIProducts } from '../../../services/api';
import ButtonTableActionRemove from '../../../components/products/Action.Remove.vue';
import ButtonTableActionEdit from '../../../components/products/Action.Edit.vue';
import ButtonActionCreate from '../../../components/products/Action.Create.vue';
import ButtonActionImport from '../components/Action.Import.vue';
import ButtonActionExport from '../components/Action.Export.vue';
import ActionInfo from '../../../components/products/Action.Info.vue';
import VisKPI from '../../../components/common/Vis.KPI.vue';
import Dashboard from '../../../components/common/Dashboard.vue';
import DashboardItem from '../../../components/common/Dashboard.Item.vue';

const tableHeaders = [
  { key: 'enabled', title: 'Enabled' },
  { key: 'name', title: 'Name' },
  { key: 'url', title: 'URL' },
  { key: 'created_at', title: 'Created at' },
  { key: 'updated_at', title: 'Updated at' },
  { title: 'Actions', align: 'end', key: 'actions', sortable: false },
];

const refetchTs = ref(0);

const fetchData = props => {
  const { page, itemsPerPage, search, sortBy } = props;
  return APIProducts.getList({ page, itemsPerPage, search, sortBy }).then(
    ({ body: { items, total_items } }) => ({ items, total_items }),
  );
};

function updateRefetch() {
  refetchTs.value = refetchTs.value + 1;
}
const initialSortBy = [{ key: 'id', order: 'asc' }];

function getItemCount() {
  return APIProducts.getList({ itemsPerPage: 1 }).then(
    ({ body: { total_items } }) => total_items,
  );
}
</script>

<template>
  <Dashboard>
    <DashboardItem :span="4">
      <VisKPI
        :fetch="getItemCount"
        label="Total items"
        :refetch="refetchTs"
      ></VisKPI>
    </DashboardItem>
  </Dashboard>
  <TableItems
    :fetch="fetchData"
    :table-headers="tableHeaders"
    title="Items"
    :refetch="refetchTs"
    :sortBy="initialSortBy"
  >
    <template v-slot:item.enabled="{ field }">
      <span>{{ field ? '✅' : '' }}</span>
    </template>
    <template v-slot:item.name="{ field, item }">
      <ActionInfo :item="item"></ActionInfo>
    </template>
    <template v-slot:item.url="{ field }">
      <a :href="field" target="_blank" rel="noopener noreferrer">link</a>
    </template>
    <template v-slot:external.actions="">
      <ButtonActionCreate @on-create="updateRefetch"></ButtonActionCreate>
      <ButtonActionImport @on-confirm="updateRefetch"></ButtonActionImport>
      <ButtonActionExport></ButtonActionExport>
    </template>

    <template v-slot:actions="{ item }">
      <ButtonTableActionEdit
        :record="item"
        @on-edit="updateRefetch"
      ></ButtonTableActionEdit>
      <ButtonTableActionRemove
        :item="item"
        @on-remove="updateRefetch"
      ></ButtonTableActionRemove>
    </template>
  </TableItems>
</template>
