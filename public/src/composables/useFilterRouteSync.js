import { watch } from "vue";
import { useRoute, useRouter } from "vue-router";

// Two-way sync between a list store's `filters` and the current route's
// query string - shared by every store-backed list view (Alerts,
// Observations, Deliveries, Rules).
//
// Any store filter field can be deep-linked via a matching query param
// (e.g. the Alerts table's "Observation #N" column links to Observations
// with `?id=`).
// Watching route.query (not onMounted) is required so clicking between two
// links that both resolve to the same route - which only changes the query
// on an already-mounted instance - still re-applies the filter. The watch
// source is limited to just the filter-relevant query keys (serialized,
// since route.query is a new object reference on every navigation) so
// toggling an unrelated query param - e.g. a details flyout id - doesn't
// re-trigger a filter reset/refetch and silently jump pagination back to
// page 0.
//
// `extraQueryKeys` re-attaches a view's own non-filter query params (e.g.
// AlertsListView's `details` flyout id) across onFilterChange's
// router.replace, since that rebuilds the query from scratch and would
// otherwise silently drop them.
export function useFilterRouteSync(store, { extraQueryKeys = [] } = {}) {
  const route = useRoute();
  const router = useRouter();

  watch(
    () => {
      const filterQuery = {};
      for (const key of Object.keys(store.filters)) {
        if (key in route.query) filterQuery[key] = route.query[key];
      }
      return JSON.stringify(filterQuery);
    },
    () => {
      const patch = {};
      for (const key of Object.keys(store.filters)) {
        if (key in route.query) patch[key] = route.query[key] || "";
      }

      if (Object.keys(patch).length > 0) {
        store.setFilter(patch);
      } else {
        store.fetchList();
      }
    },
    { immediate: true },
  );

  function onFilterChange() {
    const query = {};
    for (const [key, value] of Object.entries(store.filters)) {
      if (value !== "" && value != null) query[key] = value;
    }
    for (const key of extraQueryKeys) {
      if (route.query[key]) query[key] = route.query[key];
    }
    router.replace({ query });
  }

  function onFilterUpdate(patch) {
    Object.assign(store.filters, patch);
    onFilterChange();
  }

  return { onFilterChange, onFilterUpdate };
}
