// Triggers a browser download of `content` (a string or Blob) as
// `filename`. Can't just be a plain `<a href="/api/rules/export">` link -
// the API is JWT-header-authenticated, so a bare link can't carry the
// Authorization header; content must be fetched via `http()` first and
// handed to this as a blob/string.
export function downloadBlob(content, filename, mimeType) {
  const blob = content instanceof Blob ? content : new Blob([content], { type: mimeType });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = filename;
  document.body.appendChild(link);
  link.click();
  document.body.removeChild(link);
  URL.revokeObjectURL(url);
}

function getFilenameFromHeader(response, defaultName) {
  const contentDisposition = response.headers.get('Content-Disposition');
  if (!contentDisposition) return defaultName;

  const filenameRegex = /filename[^;=\n]*=((['"]).*?\2|[^;\n]*)/;
  const matches = filenameRegex.exec(contentDisposition);
  if (matches != null && matches[1]) {
    return matches[1].replace(/['"]/g, '');
  }
  return defaultName;
}

// Downloads a JSON-export response, reading the filename off its
// Content-Disposition header. Used by the plain-JSON export endpoints
// (observables/observable_types/notification_channels), as opposed to
// downloadBlob above which takes already-fetched content directly.
export function downloadFileFromResponse(response, defaultName) {
  let data = response.body;
  const type = response.headers.get('content-type');

  if (type === 'application/json') {
    data = JSON.stringify(data);
  }
  const blob = new Blob([data], { type });
  const url = URL.createObjectURL(blob);

  const a = document.createElement('a');
  a.href = url;
  a.download = getFilenameFromHeader(response, defaultName);
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
}
