// Drives DataTable.vue with dynamic, per-observable-type columns without any
// change to DataTable.vue itself: it already falls back to
// `item[column.key] ?? '-'` when no `#cell-<key>` slot is provided, so
// spreading a row's `properties` object onto the row itself makes every
// property directly addressable as a plain column key.
//
// Only fields marked list_column become columns (curated per type via
// PropertySchemaEditor's "Show as column" checkbox) - pure opt-in, no
// fallback, mirroring ObserverConfigsListView.vue's own list_column-filtered
// extraColumns.
export function schemaColumns(schema) {
  return (schema || []).filter((prop) => prop.list_column).map((prop) => ({ key: prop.name, label: prop.label || prop.name }));
}

export function flattenProperties(items) {
  return (items || []).map((item) => ({ ...item, ...item.properties }));
}
