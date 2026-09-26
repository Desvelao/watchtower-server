import { describe, it, expect, vi, beforeEach } from "vitest";
import { setActivePinia, createPinia } from "pinia";

vi.mock("../services/api/auth", () => ({
  login: vi.fn(),
  getMe: vi.fn(),
}));

import * as authApi from "../services/api/auth";
import { useAuthStore } from "./auth";

const STORAGE_KEY = "watchtower_auth";

describe("useAuthStore", () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    localStorage.clear();
    vi.clearAllMocks();
  });

  describe("can", () => {
    it("returns true when the permission is present", () => {
      const store = useAuthStore();
      store.permissions = ["alerts:read"];
      expect(store.can("alerts:read")).toBe(true);
    });

    it("returns false when the permission is absent", () => {
      const store = useAuthStore();
      store.permissions = ["alerts:read"];
      expect(store.can("alerts:write")).toBe(false);
    });
  });

  describe("restore", () => {
    it("is a no-op when nothing is persisted", async () => {
      const store = useAuthStore();
      await store.restore();
      expect(store.token).toBeNull();
      expect(authApi.getMe).not.toHaveBeenCalled();
    });

    it("clears storage and returns early on malformed JSON", async () => {
      localStorage.setItem(STORAGE_KEY, "{not json");
      const store = useAuthStore();
      await store.restore();
      expect(store.token).toBeNull();
      expect(localStorage.getItem(STORAGE_KEY)).toBeNull();
      expect(authApi.getMe).not.toHaveBeenCalled();
    });

    it("loads persisted state and self-heals permissions via refreshMe on success", async () => {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({ token: "tok", role: "operator", username: "alice", permissions: ["alerts:read"] })
      );
      authApi.getMe.mockResolvedValue({ role: "admin", username: "alice", permissions: ["alerts:read", "alerts:write"] });

      const store = useAuthStore();
      await store.restore();

      expect(store.token).toBe("tok");
      expect(store.role).toBe("admin");
      expect(store.permissions).toEqual(["alerts:read", "alerts:write"]);
      expect(JSON.parse(localStorage.getItem(STORAGE_KEY)).role).toBe("admin");
    });

    it("keeps the stale persisted state and does not rethrow when refreshMe fails", async () => {
      localStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({ token: "tok", role: "operator", username: "alice", permissions: ["alerts:read"] })
      );
      authApi.getMe.mockRejectedValue(new Error("401"));

      const store = useAuthStore();
      await expect(store.restore()).resolves.toBeUndefined();

      expect(store.token).toBe("tok");
      expect(store.role).toBe("operator");
      expect(store.permissions).toEqual(["alerts:read"]);
    });

    it("does not call refreshMe when the persisted state has no token", async () => {
      localStorage.setItem(STORAGE_KEY, JSON.stringify({ token: null, role: null, username: null, permissions: [] }));
      const store = useAuthStore();
      await store.restore();
      expect(authApi.getMe).not.toHaveBeenCalled();
    });
  });

  describe("login", () => {
    it("composes authApi.login + refreshMe and persists the result", async () => {
      authApi.login.mockResolvedValue({ token: "new-tok" });
      authApi.getMe.mockResolvedValue({ role: "viewer", username: "bob", permissions: ["events:read"] });

      const store = useAuthStore();
      await store.login("bob", "secret");

      expect(authApi.login).toHaveBeenCalledWith("bob", "secret");
      expect(store.token).toBe("new-tok");
      expect(store.username).toBe("bob");
      expect(store.role).toBe("viewer");
      expect(store.permissions).toEqual(["events:read"]);
      expect(JSON.parse(localStorage.getItem(STORAGE_KEY)).token).toBe("new-tok");
    });
  });

  describe("logout", () => {
    it("clears state and localStorage", () => {
      const store = useAuthStore();
      store.token = "tok";
      store.role = "admin";
      store.username = "alice";
      store.permissions = ["alerts:read"];
      localStorage.setItem(STORAGE_KEY, "{}");

      store.logout();

      expect(store.token).toBeNull();
      expect(store.role).toBeNull();
      expect(store.username).toBeNull();
      expect(store.permissions).toEqual([]);
      expect(localStorage.getItem(STORAGE_KEY)).toBeNull();
    });
  });
});
