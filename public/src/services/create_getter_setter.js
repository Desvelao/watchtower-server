const cache = {};

export function createGetterSetter(context) {
  return [() => cache[context], value => (cache[context] = value)];
}
