import { getServices } from './services';

const base = '/api/items';

export async function importFile(file) {
  const formData = new FormData();
  formData.append('file', file);

  return getServices().http(`${base}/import`, {
    method: 'post',
    body: formData,
  });
}

function getFilenameFromHeader(response, defaultName) {
  const contentDisposition = response.headers.get('Content-Disposition');
  if (!contentDisposition) return 'default.txt';

  const filenameRegex = /filename[^;=\n]*=((['"]).*?\2|[^;\n]*)/;
  const matches = filenameRegex.exec(contentDisposition);
  if (matches != null && matches[1]) {
    return matches[1].replace(/['"]/g, '');
  }
  return defaultName;
}

async function downloadFileFromResponse(response, defaultName) {
  let data = response.body;

  let type = response.headers.get('content-type');

  if (type === 'application/json') {
    data = JSON.stringify(data);
  }
  const blob = new Blob([data], {
    type,
  }); // adjust MIME type as needed
  const url = URL.createObjectURL(blob);

  const a = document.createElement('a');
  a.href = url;
  a.download = getFilenameFromHeader(response, defaultName);
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url); // cleanup
}

export async function exportFile() {
  const response = await getServices().http(`${base}/export`, {
    method: 'get',
  });

  downloadFileFromResponse(response, 'export.json');
}
