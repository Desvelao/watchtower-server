import { unref, isReactive, isRef } from 'vue';

export function toRawObject(obj) {
  // If it's a ref, unref it and process the value
  if (isRef(obj)) {
    return toRawObject(unref(obj));
  }

  // If it's a reactive object, convert each property recursively
  if (isReactive(obj) || typeof obj === 'object') {
    const result = Array.isArray(obj) ? [] : {};
    for (const key in obj) {
      result[key] = toRawObject(obj[key]);
    }
    return result;
  }

  // If it's a primitive or non-reactive value, return as is
  return obj;
}
