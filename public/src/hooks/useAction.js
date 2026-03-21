import { ref } from 'vue';

export function useAsyncAction(fn, options = {}) {
  const isRunning = ref(false);
  const data = ref(options.data || null);
  const error = ref(null);

  const run = async (...args) => {
    try {
      error.value = null;
      isRunning.value = true;
      const r = await fn(...args);
      data.value = r;
    } catch (err) {
      error.value = err;
    } finally {
      isRunning.value = false;
    }
  };

  return { isRunning, data, error, run };
}
