// PitHub UI 工具：图标、Toast、模态框、格式化、主题。

const ICON_PATHS = {
  dashboard: '<path d="M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z"/>',
  folder: '<path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h5l1.5 2h8.5A1.5 1.5 0 0 1 21 8.5v9A1.5 1.5 0 0 1 19.5 19h-15A1.5 1.5 0 0 1 3 17.5z"/>',
  photo: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><circle cx="8.5" cy="9.5" r="1.6"/><path d="m4 17 5-4.5 4 3.5 3-2.5 4 3.5"/>',
  clipboard: '<rect x="5" y="5" width="14" height="16" rx="2.5"/><path d="M9 5V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v1"/><path d="M9 10h6M9 14h6"/>',
  bolt: '<path d="M13 2 4.5 13.5H11l-1 8.5L19 10h-6.5z"/>',
  logs: '<path d="M5 4h14v16H5z"/><path d="M8 8h8M8 12h8M8 16h5"/>',
  settings: '<circle cx="12" cy="12" r="3"/><path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M18.4 5.6 17 7M7 17l-1.4 1.4"/>',
  moon: '<path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5z"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5 19 19M19 5l-1.5 1.5M6.5 17.5 5 19"/>',
  logout: '<path d="M10 5H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h4"/><path d="m15 8 4 4-4 4M19 12H9"/>',
  menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
  close: '<path d="m6 6 12 12M18 6 6 18"/>',
  upload: '<path d="M12 16V4M7 9l5-5 5 5"/><path d="M4 16v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  download: '<path d="M12 4v12M7 11l5 5 5-5"/><path d="M4 19h16"/>',
  share: '<circle cx="6" cy="12" r="2.2"/><circle cx="18" cy="6" r="2.2"/><circle cx="18" cy="18" r="2.2"/><path d="m8 11 8-4M8 13l8 4"/>',
  trash: '<path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v6M14 11v6"/>',
  edit: '<path d="M4 20h4l10.5-10.5a2.1 2.1 0 0 0-3-3L5 17z"/><path d="M15.5 5.5 19 9"/>',
  move: '<path d="M4 9h11M9 4l5 5-5 5"/><path d="M20 18V9a2 2 0 0 0-2-2h-3"/>',
  more: '<circle cx="6" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="18" cy="12" r="1.3"/>',
  chevronRight: '<path d="m9 5 7 7-7 7"/>',
  chevronLeft: '<path d="m15 5-7 7 7 7"/>',
  refresh: '<path d="M20 11a8 8 0 1 0-2 5"/><path d="M20 5v6h-6"/>',
  copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',
  check: '<path d="m4 12 5 5L20 6"/>',
  file: '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4"/>',
  video: '<rect x="3" y="6" width="13" height="12" rx="2"/><path d="m16 10 5-2v8l-5-2z"/>',
  image: '<rect x="3" y="4" width="18" height="16" rx="2.5"/><circle cx="9" cy="10" r="1.4"/><path d="m4 18 5-4 4 3 3-2.5 4 3.5"/>',
  pdf: '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4M9 13h6M9 16h4"/>',
  text: '<path d="M5 5h14M5 10h14M5 15h9"/>',
  audio: '<path d="M4 14v-4M8 18V6M12 16V8M16 20V4M20 14v-4"/>',
  archive: '<rect x="4" y="4" width="16" height="16" rx="2"/><path d="M10 4v4h4V4M12 10h.01M12 14h.01M12 18h.01"/>',
  search: '<circle cx="11" cy="11" r="6"/><path d="m16 16 4.5 4.5"/>',
  lock: '<rect x="5" y="10" width="14" height="10" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3"/>',
  globe: '<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17M12 3.5c2.4 2.5 3.6 5.4 3.6 8.5s-1.2 6-3.6 8.5c-2.4-2.5-3.6-5.4-3.6-8.5s1.2-6 3.6-8.5z"/>',
  wifi: '<path d="M3 9a13 13 0 0 1 18 0M6 12.5a8.5 8.5 0 0 1 12 0M9 16a4 4 0 0 1 6 0"/><circle cx="12" cy="19" r="1"/>',
  link: '<path d="M10 14a4 4 0 0 0 6 0l2-2a4 4 0 0 0-6-6l-1 1"/><path d="M14 10a4 4 0 0 0-6 0l-2 2a4 4 0 0 0 6 6l1-1"/>',
  server: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
  play: '<path d="m8 5 11 7-11 7z"/>',
  stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
  warning: '<path d="M12 4 2.8 20h18.4z"/><path d="M12 9v5M12 17h.01"/>',
  external: '<path d="M14 4h6v6M20 4 11 13"/><path d="M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4"/>',
  qr: '<rect x="4" y="4" width="6" height="6"/><rect x="14" y="4" width="6" height="6"/><rect x="4" y="14" width="6" height="6"/><path d="M14 14h2v2h-2zM18 14h2M14 18h2M18 18h2v2h-2"/>',
  tag: '<path d="M3 12V5a2 2 0 0 1 2-2h7l9 9-9 9z"/><circle cx="8" cy="8" r="1.4"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>'
};

export function icon(name, cls = 'w-4 h-4') {
  const path = ICON_PATHS[name] || ICON_PATHS.file;
  return `<svg class="${cls}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${path}</svg>`;
}

export function escapeHtml(value) {
  return String(value == null ? '' : value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function formatBytes(bytes) {
  const value = Number(bytes || 0);
  if (!Number.isFinite(value) || value <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let size = value;
  let index = 0;
  while (size >= 1024 && index < units.length - 1) {
    size /= 1024;
    index += 1;
  }
  return index === 0 ? `${Math.round(size)} B` : `${size.toFixed(1)} ${units[index]}`;
}

export function formatDate(value) {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString('zh-CN', {
    year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit'
  });
}

export function formatShortDate(value) {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString('zh-CN', { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
}

export function formatDuration(seconds) {
  const total = Math.max(0, Math.round(Number(seconds) || 0));
  const minutes = Math.floor(total / 60);
  const rest = total % 60;
  return `${minutes}:${String(rest).padStart(2, '0')}`;
}

export function kindIcon(kind, isDirectory) {
  if (isDirectory) return 'folder';
  switch (String(kind || '').toLowerCase()) {
    case 'image': return 'image';
    case 'video': return 'video';
    case 'pdf': return 'pdf';
    case 'text': return 'text';
    case 'audio': return 'audio';
    case 'archive': return 'archive';
    default: return 'file';
  }
}

export function toast(message, type = 'info', duration = 3000) {
  const root = document.getElementById('toast-root');
  if (!root) return;
  const node = document.createElement('div');
  const colorClass = type === 'error' ? 'toast-error' : type === 'success' ? 'toast-success' : '';
  node.className = `toast ${colorClass}`;
  const iconName = type === 'error' ? 'warning' : type === 'success' ? 'check' : 'link';
  node.innerHTML = `${icon(iconName, 'w-4 h-4')}<span class="flex-1">${escapeHtml(message)}</span>`;
  root.appendChild(node);
  setTimeout(() => {
    node.style.opacity = '0';
    node.style.transform = 'translateY(6px)';
    node.style.transition = 'all .18s ease';
    setTimeout(() => node.remove(), 220);
  }, duration);
}

export function modal({ title = '', content = '', footer = '', wide = false, plain = false, onClose = null } = {}) {
  const root = document.getElementById('modal-root');
  if (!root) return { close: () => {} };

  const backdrop = document.createElement('div');
  backdrop.className = `modal-backdrop${plain ? ' plain' : ''}`;
  backdrop.innerHTML = `
    <div class="modal-card ${wide ? 'modal-wide' : ''}" role="dialog" aria-modal="true">
      <div class="flex items-start justify-between gap-4 mb-4">
        <div class="text-[1.02rem] font-semibold">${escapeHtml(title)}</div>
        <button class="btn btn-ghost btn-icon" data-modal-close aria-label="关闭">${icon('close', 'w-4 h-4')}</button>
      </div>
      <div data-modal-content></div>
      ${footer ? `<div class="mt-5 flex items-center justify-end gap-2" data-modal-footer>${footer}</div>` : ''}
    </div>`;
  const contentNode = backdrop.querySelector('[data-modal-content]');
  if (typeof content === 'string') contentNode.innerHTML = content;
  else contentNode.appendChild(content);
  root.appendChild(backdrop);

  const close = () => {
    backdrop.remove();
    document.removeEventListener('keydown', onKey);
    if (onClose) onClose();
  };
  const onKey = (event) => {
    if (event.key === 'Escape') close();
  };
  document.addEventListener('keydown', onKey);
  backdrop.querySelector('[data-modal-close]').addEventListener('click', close);
  backdrop.addEventListener('click', (event) => {
    if (event.target === backdrop) close();
  });

  return { root: backdrop, content: contentNode, close };
}

export function confirmDialog(title, message, confirmText = '确认', danger = true) {
  return new Promise((resolve) => {
    let settled = false;
    const dialog = modal({
      title,
      content: `<p class="text-sm leading-relaxed" style="color:var(--muted)">${escapeHtml(message)}</p>`,
      footer: `
        <button class="btn btn-ghost" data-cancel>取消</button>
        <button class="btn ${danger ? 'btn-danger' : 'btn-primary'}" data-confirm>${escapeHtml(confirmText)}</button>`,
      onClose: () => { if (!settled) { settled = true; resolve(false); } }
    });
    dialog.root.querySelector('[data-cancel]').addEventListener('click', () => {
      settled = true;
      dialog.close();
      resolve(false);
    });
    dialog.root.querySelector('[data-confirm]').addEventListener('click', () => {
      settled = true;
      dialog.close();
      resolve(true);
    });
  });
}

export async function copyText(text) {
  const value = String(text || '');
  try {
    await navigator.clipboard.writeText(value);
    toast('已复制', 'success');
  } catch {
    const area = document.createElement('textarea');
    area.value = value;
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.appendChild(area);
    area.select();
    try { document.execCommand('copy'); toast('已复制', 'success'); }
    catch { toast('复制失败', 'error'); }
    area.remove();
  }
}

export function downloadBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 4000);
}

export async function copyImageFromURL(url, filename = 'image.png') {
  try {
    const response = await fetch(url, { credentials: 'include' });
    const blob = await response.blob();
    downloadBlob(blob, filename);
  } catch {
    toast('下载失败', 'error');
  }
}

/* ---------------- 主题 ---------------- */

const THEME_KEY = 'pithub_theme';

export function getThemePreference() {
  try { return localStorage.getItem(THEME_KEY) || 'auto'; } catch { return 'auto'; }
}

export function applyTheme(preference = getThemePreference()) {
  const media = window.matchMedia('(prefers-color-scheme: light)');
  const effective = preference === 'auto' ? (media.matches ? 'light' : 'dark') : preference;
  document.documentElement.setAttribute('data-theme', effective);
  document.documentElement.style.colorScheme = effective;
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute('content', effective === 'light' ? '#f2f5fb' : '#05070c');
}

export function cycleTheme() {
  const current = getThemePreference();
  const next = current === 'auto' ? 'dark' : current === 'dark' ? 'light' : 'auto';
  try { localStorage.setItem(THEME_KEY, next); } catch {}
  applyTheme(next);
  toast(next === 'auto' ? '已跟随系统外观' : next === 'dark' ? '已切换到深色' : '已切换到浅色');
  return next;
}

export function initTheme() {
  applyTheme();
  window.matchMedia('(prefers-color-scheme: light)').addEventListener('change', () => {
    if (getThemePreference() === 'auto') applyTheme('auto');
  });
}

export function themeIcon() {
  const preference = getThemePreference();
  return preference === 'light' ? icon('sun', 'w-4 h-4') : icon('moon', 'w-4 h-4');
}

export function debounce(fn, delay = 300) {
  let timer = null;
  return (...args) => {
    clearTimeout(timer);
    timer = setTimeout(() => fn(...args), delay);
  };
}

export function safeText(value) {
  return escapeHtml(value == null ? '' : value);
}

export function roleLabel(role) {
  switch (role) {
    case 'admin': return '管理员';
    case 'user': return '用户';
    case 'guest': return '访客';
    default: return '未登录';
  }
}

export function emptyState(message, hint = '') {
  return `
    <div class="empty-state">
      <div class="w-12 h-12 mx-auto mb-3 rounded-2xl flex items-center justify-center" style="background:var(--panel)">${icon('folder', 'w-5 h-5')}</div>
      <div class="font-medium mb-1" style="color:var(--text)">${escapeHtml(message)}</div>
      ${hint ? `<div class="text-[0.72rem]">${escapeHtml(hint)}</div>` : ''}
    </div>`;
}
