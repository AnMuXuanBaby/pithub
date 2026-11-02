// PitHub 前端 API 封装（原生 fetch，无框架）
// 同一内置服务下使用 Cookie + Bearer；独立部署时可在 config.js 里配置 apiBase。

const CONFIG = window.PITHUB_CONFIG || {};
export const API_BASE = String(CONFIG.apiBase || '').replace(/\/+$/, '');
const TOKEN_KEY = 'pithub_token';

export const state = {
  auth: null,
  status: null,
  plugins: [],
  settings: null,
  route: 'dashboard'
};

export class ApiError extends Error {
  constructor(message, status, data) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.data = data || null;
  }
}

export function getToken() {
  try { return localStorage.getItem(TOKEN_KEY) || sessionStorage.getItem(TOKEN_KEY); } catch { return null; }
}

export function setToken(token, remember = true) {
  try {
    localStorage.removeItem(TOKEN_KEY);
    sessionStorage.removeItem(TOKEN_KEY);
    if (token) {
      if (remember) localStorage.setItem(TOKEN_KEY, token);
      else sessionStorage.setItem(TOKEN_KEY, token);
    }
  } catch {}
}

export function clearToken() {
  try {
    localStorage.removeItem(TOKEN_KEY);
    sessionStorage.removeItem(TOKEN_KEY);
  } catch {}
}

export function apiURL(path) {
  if (!path) return API_BASE || './';
  if (path.startsWith('http')) return path;
  // 关键：内嵌前端可能被部署在子路径下（例如 Relay 的 /t/<id>/）。
  // 使用相对地址可以同时兼容根路径、/file 这类单段页面，以及带前缀的隧道。
  const clean = path.startsWith('/') ? path.slice(1) : path;
  if (API_BASE) return API_BASE + '/' + clean;
  return clean;
}

function authHeaders() {
  const headers = {};
  const token = getToken();
  if (token) headers['Authorization'] = `Bearer ${token}`;
  return headers;
}

async function request(path, options = {}) {
  const { method = 'GET', body, headers = {}, signal, raw = false } = options;
  const finalHeaders = { Accept: 'application/json', ...authHeaders(), ...headers };
  let payload = body;

  if (body !== undefined && body !== null &&
      !(body instanceof FormData) && !(body instanceof Blob) &&
      !(body instanceof ArrayBuffer) && typeof body !== 'string') {
    finalHeaders['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }

  const response = await fetch(apiURL(path), {
    method,
    headers: finalHeaders,
    body: payload,
    credentials: 'include',
    signal
  });

  if (response.status === 401 && path !== '/api/auth/login') {
    setToken(null);
    state.auth = null;
    window.dispatchEvent(new CustomEvent('pithub-unauthorized'));
    throw new ApiError('登录已过期，请重新登录', 401);
  }

  if (raw) {
    if (!response.ok) throw new ApiError(`请求失败 (${response.status})`, response.status);
    return response;
  }

  const contentType = response.headers.get('content-type') || '';
  let data = null;
  if (contentType.includes('application/json')) {
    data = await response.json().catch(() => null);
  } else if (contentType.includes('text/')) {
    data = await response.text().catch(() => '');
  }

  if (!response.ok) {
    const message = (data && data.error) || `请求失败 (${response.status})`;
    throw new ApiError(message, response.status, data);
  }
  return data;
}

export function uploadRaw(path, blob, { method = 'POST', headers = {}, onProgress } = {}) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest();
    xhr.open(method, apiURL(path), true);
    const token = getToken();
    if (token) xhr.setRequestHeader('Authorization', `Bearer ${token}`);
    xhr.setRequestHeader('Accept', 'application/json');
    Object.entries(headers).forEach(([key, value]) => {
      if (value !== undefined && value !== null) xhr.setRequestHeader(key, String(value));
    });
    xhr.withCredentials = true;

    if (onProgress) {
      xhr.upload.onprogress = (event) => {
        if (event.lengthComputable) onProgress(event.loaded, event.total);
      };
    }
    xhr.onerror = () => reject(new ApiError('网络请求失败', 0));
    xhr.onload = () => {
      let data = null;
      try { data = JSON.parse(xhr.responseText); } catch {}
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve(data);
      } else if (xhr.status === 401) {
        setToken(null);
        state.auth = null;
        window.dispatchEvent(new CustomEvent('pithub-unauthorized'));
        reject(new ApiError('登录已过期', 401, data));
      } else {
        reject(new ApiError((data && data.error) || `上传失败 (${xhr.status})`, xhr.status, data));
      }
    };
    xhr.send(blob);
  });
}

async function blobURL(path) {
  const response = await fetch(apiURL(path), {
    headers: authHeaders(),
    credentials: 'include'
  });
  if (!response.ok) throw new ApiError(`请求失败 (${response.status})`, response.status);
  const blob = await response.blob();
  return URL.createObjectURL(blob);
}

async function downloadBlob(path, filename) {
  const response = await fetch(apiURL(path), {
    headers: authHeaders(),
    credentials: 'include'
  });
  if (!response.ok) throw new ApiError(`下载失败 (${response.status})`, response.status);
  const blob = await response.blob();
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename || 'download';
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
}

function query(params) {
  const search = new URLSearchParams();
  Object.entries(params || {}).forEach(([key, value]) => {
    if (value === undefined || value === null || value === '') return;
    search.set(key, String(value));
  });
  const text = search.toString();
  return text ? '?' + text : '';
}

export const api = {
  // 鉴权
  authStatus: () => request('/api/auth/status'),
  login: (role, password, remember) => request('/api/auth/login', {
    method: 'POST',
    body: { role, password, remember }
  }),
  logout: () => request('/api/auth/logout', { method: 'POST' }),

  // 状态 / 插件
  status: () => request('/api/status'),
  plugins: () => request('/api/plugin/list'),
  enablePlugin: (id) => request('/api/plugin/enable', { method: 'POST', body: { id } }),
  disablePlugin: (id) => request('/api/plugin/disable', { method: 'POST', body: { id } }),

  // 设置
  settings: () => request('/api/settings'),
  saveSettings: (payload) => request('/api/settings', { method: 'POST', body: payload }),
  tunnelGuide: () => request('/api/tunnel/guide'),

  // 日志 / 缓存 / 二维码
  logs: (offset, limit, q, method, tunnel) => request('/api/logs' + query({ offset, limit, q, method, tunnel })),
  logsExportURL: (format) => apiURL('/api/logs/export' + query({ format })),
  logsExport: (format) => downloadBlob('/api/logs/export' + query({ format }), `pithub-logs.${format}`),
  clearLogs: () => request('/api/logs/clear', { method: 'POST' }),
  clearCache: () => request('/api/cache/clear', { method: 'POST' }),
  cacheStats: () => request('/api/cache/stats'),
  qrURL: (url) => blobURL('/api/qr' + query({ url })),

  // FilePit
  fileRoots: () => request('/api/file/roots'),
  fileList: (path) => request('/api/file/list' + query({ path })),
  fileStat: (path) => request('/api/file/stat' + query({ path })),
  fileMkdir: (path) => request('/api/file/mkdir', { method: 'POST', body: { path } }),
  fileDelete: (path) => request('/api/file/delete', { method: 'POST', body: { path } }),
  fileRename: (path, name) => request('/api/file/rename', { method: 'POST', body: { path, name } }),
  fileMove: (path, destination) => request('/api/file/move', { method: 'POST', body: { path, destination } }),
  fileShare: (path, expiresMinutes, password) => request('/api/file/share', {
    method: 'POST',
    body: { path, expiresMinutes, password }
  }),
  fileShares: () => request('/api/file/shares'),
  shareDelete: (token) => request('/api/file/share/delete', { method: 'POST', body: { token } }),
  uploadInit: (path, size) => request('/api/file/upload/init', { method: 'POST', body: { path, size } }),
  uploadChunk: (uploadId, index, blob, onProgress) => uploadRaw(
    '/api/file/upload/chunk' + query({ uploadId, index }),
    blob,
    { method: 'PUT', headers: { 'Content-Type': 'application/octet-stream' }, onProgress }
  ),
  uploadComplete: (uploadId) => request('/api/file/upload/complete', { method: 'POST', body: { uploadId } }),
  uploadStatus: (uploadId) => request('/api/file/upload/status' + query({ uploadId })),
  uploadCancel: (uploadId) => request('/api/file/upload/cancel' + query({ uploadId }), { method: 'POST' }),
  uploadRaw: (path, file, onProgress) => uploadRaw(
    '/api/file/upload' + query({ path, overwrite: 1 }),
    file,
    { method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, onProgress }
  ),
  downloadFileURL: (path, inline) => apiURL('/api/file/download' + query({ path, inline: inline ? 1 : 0 })),
  zipURL: (path) => apiURL('/api/file/zip' + query({ path })),
  downloadViaFetch: (path, filename) => downloadBlob('/api/file/download' + query({ path }), filename),

  // PhotoNode
  photoStatus: () => request('/api/photo/status'),
  photoAlbums: () => request('/api/photo/albums'),
  photoAssets: (album, offset, limit, year, month) => request('/api/photo/assets' + query({ album, offset, limit, year, month })),
  photoTimeline: (album) => request('/api/photo/timeline' + query({ album })),
  photoThumbURL: (id, size = 'small') => apiURL('/api/photo/thumb' + query({ id, size })),
  photoCoverURL: (album, size = 'small') => apiURL('/api/photo/cover' + query({ album, size })),
  photoOriginalURL: (id, live, inline) => apiURL('/api/photo/original' + query({ id, live, inline: inline ? 1 : 0 })),

  // ClipHub
  clipList: (q, tag, offset, limit) => request('/api/clip/list' + query({ q, tag, offset, limit })),
  clipPush: (text, tags) => request('/api/clip/push', { method: 'POST', body: { text, kind: 'text', tags } }),
  clipDelete: (id) => request('/api/clip/delete', { method: 'POST', body: { id } }),
  clipClear: () => request('/api/clip/clear', { method: 'POST' }),
  clipTags: () => request('/api/clip/tags'),
  clipBlobURL: (id) => apiURL('/api/clip/blob' + query({ id })),

  // DashLink
  dashButtons: () => request('/api/dash/buttons'),
  dashSave: (button) => request('/api/dash/button/save', { method: 'POST', body: button }),
  dashDelete: (id) => request('/api/dash/button/delete', { method: 'POST', body: { id } }),
  dashRun: (id, text) => request('/api/dash/run', { method: 'POST', body: { id, text } }),
  dashRuns: (limit = 30) => request('/api/dash/runs' + query({ limit })),
  dashClear: () => request('/api/dash/runs/clear', { method: 'POST' }),

  raw: request,
  blobURL
};
