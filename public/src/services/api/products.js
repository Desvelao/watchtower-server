import { http } from './http';

const base = '/api/items';
/**
 *
 * @param {*} options
 * @returns
 */

/**
 * @typedef {Object} GetListOptions
 * @property {number} [page] - The page number to retrieve.
 * @property {number} [itemsPerPage] - Number of items per page.
 * @property {string} [search] - Search query string.
 * @property {Array<{key: string, order: 'asc' | 'desc'}>} [sortBy] - Sorting options.
 */

/**
 * Gets a list of items with pagination, search, and sorting options.
 * @param {GetListOptions} options
 * @returns
 */
export async function getList(options = {}) {
  const page = options.page || 1;
  const itemsPerPage = options.itemsPerPage || 10;
  const search = options.search;

  let sortBy;
  if (options.sortBy && options.sortBy[0]) {
    const { key, order } = options.sortBy[0];
    sortBy = `${key}:${order}`;
  }

  return await http(
    `${base}?size=${itemsPerPage}&from=${(page - 1) * itemsPerPage}${sortBy ? '&sort=' + sortBy : ''}${search ? '&search=' + search : ''}`,
    {
      method: 'get',
    },
  );
}

export async function get(id) {
  return await http(`${base}/${id}`, { method: 'get' });
}

export async function create(payload) {
  return await http(base, {
    method: 'post',
    body: payload,
    headers: { 'content-type': 'application/json' },
  });
}

export async function edit(id, payload) {
  return await http(`${base}/${id}`, {
    method: 'put',
    body: payload,
    headers: { 'content-type': 'application/json' },
  });
}

export async function remove(id) {
  return await http(`${base}/${id}`, { method: 'delete' });
}
