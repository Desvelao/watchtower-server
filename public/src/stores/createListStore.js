import { defineStore } from "pinia";
import { isRelativeDateKeyword, localDateTimeToServerParam } from "../utils/date";

// Builds a Pinia store definition for the shared "server-side
// search/filter/sort/paginate" list-view shape used by alerts,
// observations, rules, and deliveries - state/buildQuery/fetchList/
// setFilter/setSort/setPage/setPageSize/findById are identical across all
// four, so they live here once. Only what varies per resource - the
// `filters` defaults, the default `sort`, the list-fetching API function, and any extra
// resource-specific actions (create/remove/bulkRemove/...) - is passed in.
//
// buildQuery's *_after/*_before normalization loop runs unconditionally
// over every filter key; it's a no-op for stores (e.g. rules) whose
// `filters` have no such keys.
//
// Shared by buildQuery (list fetch) and buildExportQuery (export download,
// see below) - relative-date conversion + stripping empty/null/undefined
// values so callers can pass `filters` straight through unfiltered.
function normalizeQuery(query) {
  for (const key of Object.keys(query)) {
    if (
      (key.endsWith("_after") || key.endsWith("_before")) &&
      query[key] &&
      !isRelativeDateKeyword(query[key])
    ) {
      query[key] = localDateTimeToServerParam(query[key]);
    }
  }
  for (const key of Object.keys(query)) {
    if (query[key] === "" || query[key] === null || query[key] === undefined) {
      delete query[key];
    }
  }
  return query;
}

export function createListStore(name, { filters, sort, listFn, actions: extraActions = {} } = {}) {
  return defineStore(name, {
    state: () => ({
      items: [],
      totalItems: 0,
      filters: { ...filters },
      sort,
      pagination: { from: 0, size: 20 },
      loading: false,
      error: null,
    }),
    actions: {
      buildQuery() {
        return normalizeQuery({ ...this.filters, sort: this.sort, ...this.pagination });
      },
      // Same as buildQuery, but without pagination - an export should
      // always cover every row matching the current filters/search/sort,
      // not just the list view's current page.
      buildExportQuery(extra = {}) {
        return normalizeQuery({ ...this.filters, sort: this.sort, ...extra });
      },
      async fetchList() {
        this.loading = true;
        this.error = null;
        try {
          const { items, total_items } = await listFn(this.buildQuery());
          this.items = items || [];
          this.totalItems = total_items || 0;
        } catch (err) {
          this.error = err;
          throw err;
        } finally {
          this.loading = false;
        }
      },
      setFilter(patch) {
        Object.assign(this.filters, patch);
        this.pagination.from = 0;
        return this.fetchList();
      },
      setSort(sort) {
        this.sort = sort;
        return this.fetchList();
      },
      setPage(from) {
        this.pagination.from = from;
        return this.fetchList();
      },
      setPageSize(size) {
        this.pagination.size = size;
        this.pagination.from = 0;
        return this.fetchList();
      },
      findById(id) {
        return this.items.find((item) => String(item.id) === String(id));
      },
      ...extraActions,
    },
  });
}
