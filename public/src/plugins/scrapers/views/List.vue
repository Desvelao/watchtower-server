<script setup>
import { ref } from 'vue';
import TableItems from '../../../components/common/TableServerItems.vue';
import TableActionAsync from '../../../components/common/TableActionAsync.vue';
import ButtonActionCreate from '../components/Action.Create.vue';
import ButtonActionEdit from '../components/Action.Edit.vue';
import ButtonActionTest from '../components/Action.Test.vue';
import ButtonActionTestAllSites from '../components/Action.Test.AllSites.vue';
import ButtonActionImport from '../components/Action.Import.vue';
import ButtonActionExport from '../components/Action.Export.vue';
import ActionInfo from '../components/Action.Info.vue';
import * as ScraperAPI from '../api';
import { toRawObject } from '../utils';
import Dashboard from '../../../components/common/Dashboard.vue';
import DashboardItem from '../../../components/common/Dashboard.Item.vue';
import VisKPI from '../../../components/common/Vis.KPI.vue';

const tableHeaders = [
  // { key: 'id', title: 'ID' },
  { key: 'name', title: 'Name' },
  { key: 'urls_match', title: 'URL match' },
  { title: 'Actions', align: 'end', key: 'actions', sortable: false },
];

const refetchTs = ref(0);

function updateRefetch() {
  refetchTs.value = refetchTs.value + 1;
}

async function handleRemove(item) {
  const { id } = item;

  await ScraperAPI.remove(id);

  updateRefetch();
}

const fetchData = (props = {}) => {
  const { page, itemsPerPage, sortBy } = toRawObject(props);
  return ScraperAPI.getList({
    page,
    itemsPerPage,
    sortBy,
  }).then(({ body: { items, total_items } }) => ({ items, total_items }));
};
const initialSortBy = [{ key: 'id', order: 'asc' }];

function getItemCount() {
  return ScraperAPI.getList({ itemsPerPage: 1 }).then(
    ({ body: { total_items } }) => total_items,
  );
}
</script>

<template>
  <Dashboard>
    <DashboardItem :span="4">
      <VisKPI
        :fetch="getItemCount"
        label="Total scrapers"
        :refetch="refetchTs"
      ></VisKPI>
    </DashboardItem>
  </Dashboard>
  <TableItems
    :fetch="fetchData"
    :table-headers="tableHeaders"
    title="Scraper: Remote (Lua)"
    :refetch="refetchTs"
    :sortBy="initialSortBy"
  >
    <template v-slot:item.name="{ item }">
      <ActionInfo :data="item"></ActionInfo>
    </template>

    <template v-slot:external.actions="">
      <ButtonActionCreate @on-create="updateRefetch"></ButtonActionCreate>
      <ButtonActionImport @on-confirm="updateRefetch"></ButtonActionImport>
      <ButtonActionExport></ButtonActionExport>
      <ButtonActionTestAllSites></ButtonActionTestAllSites>
    </template>

    <template v-slot:actions="{ item }">
      <ButtonActionEdit
        :record="item"
        @on-edit="updateRefetch"
      ></ButtonActionEdit>
      <ButtonActionTest :record="item"></ButtonActionTest>
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
