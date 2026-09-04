import { defineStore } from "pinia";

const STORAGE_KEY = "price_monitor_theme";
const VALID = ["light", "dark", "system"];
const media = window.matchMedia("(prefers-color-scheme: dark)");

export const useThemeStore = defineStore("theme", {
  state: () => ({
    preference: "system",
    // Mirrors media.matches into reactive Pinia state - the isDark getter
    // is a cached computed(), and media.matches is a plain (non-reactive)
    // browser property, so reading it directly would never invalidate the
    // cache when the OS scheme changes.
    systemPrefersDark: media.matches,
  }),
  getters: {
    isDark: (state) =>
      state.preference === "dark" ||
      (state.preference === "system" && state.systemPrefersDark),
  },
  actions: {
    restore() {
      const stored = localStorage.getItem(STORAGE_KEY);
      this.preference = VALID.includes(stored) ? stored : "system";
      this.systemPrefersDark = media.matches;
      this.applyTheme();
      media.addEventListener("change", (e) => {
        this.systemPrefersDark = e.matches;
        this.applyTheme();
      });
    },
    setPreference(preference) {
      if (!VALID.includes(preference)) return;
      this.preference = preference;
      localStorage.setItem(STORAGE_KEY, preference);
      this.applyTheme();
    },
    applyTheme() {
      document.documentElement.classList.toggle("dark", this.isDark);
    },
  },
});
