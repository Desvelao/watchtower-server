import { describe, it, expect, vi, beforeEach } from "vitest";
import { setActivePinia, createPinia } from "pinia";
import { createListStore } from "./createListStore";

function makeStore(overrides = {}) {
  const listFn = vi.fn().mockResolvedValue({ items: [{ id: 1 }], total_items: 1 });
  const useTestStore = createListStore("test-list", {
    filters: { status: "", search: "" },
    sort: "created_at:desc",
    listFn,
    ...overrides,
  });
  return { store: useTestStore(), listFn };
}

describe("createListStore", () => {
  beforeEach(() => {
    setActivePinia(createPinia());
  });

  describe("buildQuery", () => {
    it("merges filters, sort, and pagination, stripping empty/null/undefined values", () => {
      const { store } = makeStore({ filters: { status: "pending", search: "", extra: null, other: undefined } });
      const query = store.buildQuery();
      expect(query).toEqual({ status: "pending", sort: "created_at:desc", from: 0, size: 20 });
    });

    it("passes a relative date keyword through unchanged", () => {
      const { store } = makeStore({ filters: { created_after: "now-24h", created_before: "" } });
      const query = store.buildQuery();
      expect(query.created_after).toBe("now-24h");
      expect(query.created_before).toBeUndefined();
    });

    it("converts a concrete local datetime value to the server's bare UTC param", () => {
      const { store } = makeStore({ filters: { created_after: "2024-01-01T10:00" } });
      const query = store.buildQuery();
      expect(query.created_after).toMatch(/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/);
      expect(query.created_after).not.toBe("2024-01-01T10:00");
    });

    it("is a no-op when the store has no created_after/created_before keys", () => {
      const { store } = makeStore({ filters: { name: "" } });
      const query = store.buildQuery();
      expect(query.created_after).toBeUndefined();
      expect(query.created_before).toBeUndefined();
    });
  });

  describe("fetchList", () => {
    it("populates items/totalItems and toggles loading on success", async () => {
      const { store, listFn } = makeStore();
      const promise = store.fetchList();
      expect(store.loading).toBe(true);
      await promise;
      expect(store.loading).toBe(false);
      expect(store.error).toBeNull();
      expect(store.items).toEqual([{ id: 1 }]);
      expect(store.totalItems).toBe(1);
      expect(listFn).toHaveBeenCalledWith(store.buildQuery());
    });

    it("defaults items/totalItems when the response omits them", async () => {
      const listFn = vi.fn().mockResolvedValue({});
      const useTestStore = createListStore("test-list-empty", { filters: {}, sort: null, listFn });
      const store = useTestStore();
      await store.fetchList();
      expect(store.items).toEqual([]);
      expect(store.totalItems).toBe(0);
    });

    it("surfaces a rejected listFn into error, stops loading, and rethrows", async () => {
      const err = new Error("network down");
      const listFn = vi.fn().mockRejectedValue(err);
      const useTestStore = createListStore("test-list-error", { filters: {}, sort: null, listFn });
      const store = useTestStore();
      await expect(store.fetchList()).rejects.toThrow("network down");
      expect(store.loading).toBe(false);
      expect(store.error).toBe(err);
    });
  });

  describe("setFilter / setSort / setPage / setPageSize", () => {
    it("setFilter merges the patch, resets pagination.from, and refetches", async () => {
      const { store, listFn } = makeStore();
      store.pagination.from = 40;
      await store.setFilter({ status: "acknowledged" });
      expect(store.filters.status).toBe("acknowledged");
      expect(store.pagination.from).toBe(0);
      expect(listFn).toHaveBeenCalledTimes(1);
    });

    it("setSort updates sort and refetches", async () => {
      const { store, listFn } = makeStore();
      await store.setSort("severity_value:asc");
      expect(store.sort).toBe("severity_value:asc");
      expect(listFn).toHaveBeenCalledTimes(1);
    });

    it("setPage updates pagination.from and refetches", async () => {
      const { store, listFn } = makeStore();
      await store.setPage(20);
      expect(store.pagination.from).toBe(20);
      expect(listFn).toHaveBeenCalledTimes(1);
    });

    it("setPageSize updates pagination.size, resets from, and refetches", async () => {
      const { store, listFn } = makeStore();
      store.pagination.from = 20;
      await store.setPageSize(50);
      expect(store.pagination.size).toBe(50);
      expect(store.pagination.from).toBe(0);
      expect(listFn).toHaveBeenCalledTimes(1);
    });
  });

  describe("findById", () => {
    it("finds an item by loosely-typed id equality", async () => {
      const listFn = vi.fn().mockResolvedValue({ items: [{ id: 7 }, { id: 8 }], total_items: 2 });
      const useTestStore = createListStore("test-list-find", { filters: {}, sort: null, listFn });
      const store = useTestStore();
      await store.fetchList();
      expect(store.findById("7")).toEqual({ id: 7 });
      expect(store.findById(8)).toEqual({ id: 8 });
      expect(store.findById(999)).toBeUndefined();
    });
  });

  it("mixes in extra resource-specific actions", () => {
    const remove = vi.fn();
    const { store } = makeStore({ actions: { remove } });
    store.remove(42);
    expect(remove).toHaveBeenCalledWith(42);
  });
});
