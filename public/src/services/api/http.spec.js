import { describe, it, expect, vi, beforeEach } from 'vitest';
import { setActivePinia, createPinia } from 'pinia';
import { http, buildQueryString, HTTPError } from './http';
import { useAuthStore } from '../../stores/auth';

function fakeResponse({
  ok = true,
  status = 200,
  statusText = 'OK',
  contentType = 'application/json',
  body = {},
} = {}) {
  const headers = {
    get: (name) => (name.toLowerCase() === 'content-type' ? contentType : null),
  };
  const clone = {
    json: vi.fn().mockResolvedValue(body),
    text: vi.fn().mockResolvedValue(typeof body === 'string' ? body : String(body)),
    blob: vi.fn().mockResolvedValue(body),
  };
  return {
    ok,
    status,
    statusText,
    headers,
    url: '',
    redirected: false,
    type: 'basic',
    clone: () => clone,
  };
}

describe('http', () => {
  beforeEach(() => {
    setActivePinia(createPinia());
    vi.stubGlobal('fetch', vi.fn());
    localStorage.clear();
  });

  it('sets the Authorization header from the auth token', async () => {
    const auth = useAuthStore();
    auth.token = 'tok123';
    fetch.mockResolvedValue(fakeResponse({ body: { ok: true } }));

    await http('/api/observables');

    const [, options] = fetch.mock.calls[0];
    expect(options.headers.get('Authorization')).toBe('Bearer tok123');
  });

  it('omits the Authorization header when skipAuth is set', async () => {
    const auth = useAuthStore();
    auth.token = 'tok123';
    fetch.mockResolvedValue(fakeResponse({ body: {} }));

    await http('/api/auth/login', { skipAuth: true });

    const [, options] = fetch.mock.calls[0];
    expect(options.headers.get('Authorization')).toBeNull();
  });

  it('JSON-encodes a body when the caller declares a JSON Content-Type', async () => {
    fetch.mockResolvedValue(fakeResponse({ body: {} }));

    await http('/api/events', {
      method: 'post',
      body: { source: 'test' },
      headers: { 'content-type': 'application/json' },
    });

    const [, options] = fetch.mock.calls[0];
    expect(options.body).toBe(JSON.stringify({ source: 'test' }));
  });

  it('passes a plain string body through unchanged', async () => {
    fetch.mockResolvedValue(fakeResponse({ body: '' }));

    await http('/api/events', { method: 'post', body: 'raw text' });

    const [, options] = fetch.mock.calls[0];
    expect(options.body).toBe('raw text');
  });

  it('parses a JSON response body', async () => {
    fetch.mockResolvedValue(fakeResponse({ contentType: 'application/json', body: { items: [] } }));
    const res = await http('/api/observables');
    expect(res.body).toEqual({ items: [] });
  });

  it('parses a text/* response body', async () => {
    fetch.mockResolvedValue(fakeResponse({ contentType: 'text/plain', body: 'hello' }));
    const res = await http('/api/observables/export');
    expect(res.body).toBe('hello');
  });

  it('falls back to blob for other content types', async () => {
    fetch.mockResolvedValue(fakeResponse({ contentType: 'application/zip', body: 'zip-bytes' }));
    const res = await http('/api/rules/export');
    expect(res.body).toBe('zip-bytes');
  });

  it('throws HTTPError with the enhanced response on a non-ok response', async () => {
    fetch.mockResolvedValue(
      fakeResponse({ ok: false, status: 400, statusText: 'Bad Request', body: { message: 'invalid' } }),
    );

    await expect(http('/api/events')).rejects.toMatchObject({
      name: 'HTTPError',
      response: expect.objectContaining({ status: 400, body: { message: 'invalid' } }),
    });
  });

  it('is an instance of HTTPError and Error', async () => {
    fetch.mockResolvedValue(fakeResponse({ ok: false, status: 500, statusText: 'Server Error', body: {} }));
    try {
      await http('/api/events');
      throw new Error('should have thrown');
    } catch (err) {
      expect(err).toBeInstanceOf(HTTPError);
      expect(err).toBeInstanceOf(Error);
    }
  });

  it('logs out on a 401 unless skipAuth is set', async () => {
    const auth = useAuthStore();
    auth.token = 'tok123';
    const logoutSpy = vi.spyOn(auth, 'logout');
    fetch.mockResolvedValue(fakeResponse({ ok: false, status: 401, statusText: 'Unauthorized', body: {} }));

    await expect(http('/api/observables')).rejects.toThrow();

    expect(logoutSpy).toHaveBeenCalledTimes(1);
  });

  it('does not log out on a 401 when skipAuth is set', async () => {
    const auth = useAuthStore();
    const logoutSpy = vi.spyOn(auth, 'logout');
    fetch.mockResolvedValue(fakeResponse({ ok: false, status: 401, statusText: 'Unauthorized', body: {} }));

    await expect(http('/api/auth/login', { skipAuth: true })).rejects.toThrow();

    expect(logoutSpy).not.toHaveBeenCalled();
  });
});

describe('buildQueryString', () => {
  it('skips null, undefined, and empty-string values', () => {
    expect(buildQueryString({ a: '1', b: null, c: undefined, d: '' })).toBe('?a=1');
  });

  it('returns an empty string when there is nothing to serialize', () => {
    expect(buildQueryString({ a: null, b: undefined, c: '' })).toBe('');
    expect(buildQueryString()).toBe('');
  });

  it('serializes multiple values', () => {
    const qs = buildQueryString({ a: '1', b: '2' });
    expect(qs).toBe('?a=1&b=2');
  });
});
