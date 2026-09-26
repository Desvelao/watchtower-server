// Resolves an observable_type_id to its display label, client-side, against
// an already-fetched observableTypesStore.items list - the same "resolve
// via useObservableTypesStore" pattern ObservationsListView.vue/
// ObservablesListView.vue already use for their own observable_type_id
// filters, pulled out here since AlertsListView.vue and both detail flyouts
// need the identical lookup.
export function observableTypeLabel(observableTypeId, observableTypes) {
  if (observableTypeId == null) return '-';
  const type = observableTypes.find((t) => String(t.id) === String(observableTypeId));
  if (!type) return '-';
  return type.label || type.name || '-';
}
