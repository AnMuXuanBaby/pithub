//
// FilePit 文件面板：目录树、列表/网格、上传（分片+断点续传）、分享、预览、ZIP。
//

import { api, state } from './api.js';
import {
  icon, escapeHtml, formatBytes, formatDate, toast, modal, confirmDialog,
  copyText, kindIcon, emptyState
} from './ui.js';
import { renderShell } from './shell.js';

const fp = {
  path: '/',
  roots: [],
  entries: [],
  breadcrumb: [],
  view: 'list',
  selected: new Set(),
  loading: false,
  error: '',
  uploading: false
};

function isUser() { return state.auth && (state.auth.role === 'user' || state.auth.role === 'admin'); }
function isAdmin() { return state.auth && state.auth.role === 'admin'; }

function joinPath(dir, name) {
  if (!dir || dir === '/') return '/' + name;
  return dir.replace(/\/+$/, '') + '/' + name;
}

function parentPath(path) {
  const parts = path.replace(/^\/+|\/+$/g, '').split('/').filter(Boolean);
  if (parts.length <= 1) return '/';
  return '/' + parts.slice(0, -1).join('/');
}

function escapeAttr(value) {
  return escapeHtml(value).replace(/`/g, '&#96;');
}

function isImage(entry) {
  return !entry.isDirectory && String(entry.kind) === 'image';
}

function fileIcon(entry) {
  return kindIcon(entry.kind, entry.isDirectory);
}

/* ---------------- 页面 ---------------- */

export async function renderFilePit() {
  const params = new URLSearchParams((location.hash.split('?')[1] || ''));
  const initial = params.get('path');
  if (initial) fp.path = initial;

  renderShell('file', 'FilePit', layoutHTML());

  try {
    const data = await api.fileList(fp.path);
    applyListData(data);
    fp.error = '';
  } catch (error) {
    fp.error = error.message || '无法加载目录';
    fp.entries = [];
  }
  updateRoots();
  updateMain();
  bindShellExtras();
}

function layoutHTML() {
  return `
    <div class="grid lg:grid-cols-[228px_minmax(0,1fr)] gap-4 items-start">
      <aside class="glass p-3 lg:sticky lg:top-[84px]">
        <div class="flex items-center gap-2 px-1 mb-2">
          <div class="section-title">挂载目录</div>
          <span class="badge ml-auto">${fp.roots.length || 5}</span>
        </div>
        <div id="fp-roots" class="flex lg:flex-col gap-1 overflow-x-auto pb-1 lg:pb-0 hide-scrollbar"></div>
        <div class="divider my-3"></div>
        <div class="px-2 text-[0.66rem] leading-relaxed" style="color:var(--muted-2)">
          网页面板、HTTP API、WebDAV 使用同一套权限。访客只读，私有目录仅管理员。
        </div>
      </aside>
      <section class="min-w-0">
        <div id="fp-main"></div>
      </section>
    </div>`;
}

function rootsHTML() {
  const activeRoot = fp.path.split('/').filter(Boolean)[0];
  return fp.roots.map((root) => {
    const active = activeRoot === root.id;
    const iconName = root.id === 'photos' ? 'photo' : root.id === 'private' ? 'lock' : root.id === 'uploads' ? 'upload' : 'folder';
    return `
      <button class="nav-link !py-2 ${active ? 'active' : ''} whitespace-nowrap" data-root="${escapeAttr(root.path)}">
        <span class="nav-icon">${icon(iconName, 'w-[1.05rem] h-[1.05rem]')}</span>
        <span class="flex-1 text-left">${escapeHtml(root.name)}</span>
        ${root.readOnly ? '<span class="text-[0.58rem] muted-2">只读</span>' : ''}
      </button>`;
  }).join('') || '<div class="text-[0.7rem] muted px-2">暂无可用目录</div>';
}

function mainHTML() {
  if (fp.error) {
    return `
      <div class="glass p-6">
        <div class="flex items-start gap-3">
          <div style="color:var(--danger)">${icon('warning', 'w-5 h-5')}</div>
          <div class="flex-1">
            <div class="font-semibold text-[0.9rem]">无法打开目录</div>
            <div class="text-[0.72rem] muted mt-1">${escapeHtml(fp.error)}</div>
            <div class="flex gap-2 mt-4">
              <button class="btn btn-primary btn-sm" data-fp-home>返回根目录</button>
              <button class="btn btn-ghost btn-sm" data-fp-refresh>${icon('refresh', 'w-3.5 h-3.5')}重试</button>
            </div>
          </div>
        </div>
      </div>`;
  }

  const crumbs = fp.breadcrumb.length
    ? fp.breadcrumb
    : [{ name: 'PitHub', path: '/' }, ...fp.path.split('/').filter(Boolean).map((part, index, array) => ({
        name: part,
        path: '/' + array.slice(0, index + 1).join('/')
      }))];

  return `
    <div class="glass overflow-hidden">
      <div class="p-4 border-b" style="border-color:var(--border)">
        <div class="flex flex-wrap items-center gap-2">
          <button class="btn btn-ghost btn-icon ${fp.path === '/' ? 'disabled' : ''}" data-fp-up title="上一级">${icon('chevronLeft', 'w-4 h-4')}</button>
          <div class="flex items-center gap-1 flex-wrap min-w-0" id="fp-breadcrumb">
            ${crumbs.map((crumb, index) => `
              <button class="text-[0.72rem] px-1.5 py-1 rounded-lg hover:bg-[var(--panel)] ${index === crumbs.length - 1 ? 'font-semibold' : 'muted'}"
                data-crumb="${escapeAttr(crumb.path)}">${escapeHtml(crumb.name)}</button>
              ${index < crumbs.length - 1 ? '<span class="muted-2 text-[0.6rem]">/</span>' : ''}
            `).join('')}
          </div>
          <div class="ml-auto flex items-center gap-1.5 flex-wrap">
            ${isUser() && fp.path !== '/' ? `<button class="btn btn-primary btn-sm" data-fp-upload>${icon('upload', 'w-3.5 h-3.5')}上传</button>` : ''}
            ${isUser() && fp.path !== '/' ? `<button class="btn btn-ghost btn-sm" data-fp-mkdir>${icon('plus', 'w-3.5 h-3.5')}新建</button>` : ''}
            ${fp.path !== '/' ? `<button class="btn btn-ghost btn-sm" data-fp-zip title="ZIP 打包当前目录">${icon('archive', 'w-3.5 h-3.5')}ZIP</button>` : ''}
            <div class="flex rounded-xl p-1" style="background:rgba(0,0,0,.16)">
              <button class="btn btn-sm ${fp.view === 'list' ? 'btn-primary' : ''}" data-fp-view="list">${icon('logs', 'w-3.5 h-3.5')}</button>
              <button class="btn btn-sm ${fp.view === 'grid' ? 'btn-primary' : ''}" data-fp-view="grid">${icon('dashboard', 'w-3.5 h-3.5')}</button>
            </div>
            <button class="btn btn-ghost btn-icon btn-sm" data-fp-refresh title="刷新">${icon('refresh', 'w-3.5 h-3.5')}</button>
          </div>
        </div>
        <div id="fp-selection" class="mt-3 hidden">
          <div class="flex flex-wrap items-center gap-2 p-2 rounded-xl" style="background:var(--accent-soft)">
            <span class="text-[0.7rem] font-semibold" id="fp-selected-count">0 项已选</span>
            <button class="btn btn-ghost btn-sm" data-fp-bulk-download>${icon('download', 'w-3.5 h-3.5')}下载</button>
            ${isUser() ? `<button class="btn btn-ghost btn-sm" data-fp-bulk-move>${icon('move', 'w-3.5 h-3.5')}移动</button>` : ''}
            ${isUser() ? `<button class="btn btn-danger btn-sm" data-fp-bulk-delete>${icon('trash', 'w-3.5 h-3.5')}删除</button>` : ''}
            <button class="btn btn-ghost btn-sm ml-auto" data-fp-clear-selection>取消选择</button>
          </div>
        </div>
      </div>
      <div class="relative min-h-[320px]" id="fp-body">
        ${bodyHTML()}
      </div>
    </div>`;
}

function bodyHTML() {
  if (fp.loading) {
    return `<div class="p-8 flex items-center justify-center gap-3 text-[0.75rem] muted"><span class="skeleton w-4 h-4 rounded-full"></span>正在读取目录…</div>`;
  }
  if (!fp.entries.length) {
    return emptyState('这个目录还是空的', isUser() ? '可以直接拖拽文件到此处，或点击右上角上传。' : '访客为只读权限');
  }
  return fp.view === 'grid' ? gridHTML() : listHTML();
}

function listHTML() {
  return `
    <div class="p-2">
      ${fp.entries.map((entry) => {
        const selected = fp.selected.has(entry.path);
        const thumb = isImage(entry)
          ? `<img src="${api.filePreviewURL(entry.path, 512)}" loading="lazy" alt="" class="w-full h-full object-cover">`
          : icon(fileIcon(entry), 'w-4 h-4');
        return `
          <div class="file-row ${selected ? 'selected' : ''}" data-entry-path="${escapeAttr(entry.path)}" data-entry-dir="${entry.isDirectory ? '1' : '0'}">
            <input type="checkbox" data-fp-select="${escapeAttr(entry.path)}" ${selected ? 'checked' : ''} class="w-3.5 h-3.5 accent-[var(--accent)]">
            <div class="file-icon">${thumb}</div>
            <button class="min-w-0 flex-1 text-left" data-fp-open="${escapeAttr(entry.path)}">
              <div class="text-[0.8rem] font-medium truncate">${escapeHtml(entry.name)}</div>
              <div class="text-[0.62rem] muted flex items-center gap-2 mt-0.5">
                <span>${entry.isDirectory ? (entry.assetCount ? entry.assetCount + ' 项' : '文件夹') : formatBytes(entry.size)}</span>
                ${entry.modified ? `<span>${escapeHtml(formatDate(entry.modified * 1000))}</span>` : ''}
                ${entry.isLivePhoto ? '<span class="badge badge-accent">LIVE</span>' : ''}
                ${entry.isReadOnly ? '<span class="badge">只读</span>' : ''}
              </div>
            </button>
            <button class="btn btn-ghost btn-icon btn-sm" data-fp-menu="${escapeAttr(entry.path)}" title="更多">${icon('more', 'w-3.5 h-3.5')}</button>
          </div>`;
      }).join('')}
    </div>`;
}

function gridHTML() {
  return `
    <div class="p-3 grid grid-cols-2 sm:grid-cols-3 xl:grid-cols-5 gap-3">
      ${fp.entries.map((entry) => {
        const selected = fp.selected.has(entry.path);
        const thumb = isImage(entry)
          ? `<img src="${api.filePreviewURL(entry.path, 512)}" loading="lazy" alt="">`
          : `<div class="w-full h-full flex items-center justify-center" style="color:var(--muted)">${icon(fileIcon(entry), 'w-9 h-9')}</div>`;
        return `
          <div class="file-grid-card ${selected ? 'ring-2' : ''}" data-entry-path="${escapeAttr(entry.path)}" data-entry-dir="${entry.isDirectory ? '1' : '0'}"
               style="${selected ? 'border-color:var(--accent)' : ''}">
            <div class="file-grid-thumb" data-fp-open="${escapeAttr(entry.path)}">${thumb}</div>
            <div class="p-2.5">
              <div class="flex items-center gap-1.5">
                <input type="checkbox" data-fp-select="${escapeAttr(entry.path)}" ${selected ? 'checked' : ''} class="w-3.5 h-3.5 accent-[var(--accent)]">
                <div class="text-[0.72rem] font-medium truncate flex-1">${escapeHtml(entry.name)}</div>
                <button class="muted-2" data-fp-menu="${escapeAttr(entry.path)}">${icon('more', 'w-3.5 h-3.5')}</button>
              </div>
              <div class="text-[0.6rem] muted mt-1">${entry.isDirectory ? '文件夹' : formatBytes(entry.size)}</div>
            </div>
          </div>`;
      }).join('')}
    </div>`;
}

/* ---------------- 数据 ---------------- */

function applyListData(data) {
  if (!data) return;
  fp.path = data.path || fp.path;
  fp.entries = data.entries || [];
  fp.roots = data.roots || fp.roots;
  fp.breadcrumb = data.breadcrumb || [];
  fp.selected.clear();
}

async function loadDirectory(path, options = {}) {
  fp.loading = true;
  fp.error = '';
  updateMain();
  try {
    const data = await api.fileList(path);
    applyListData(data);
    const hash = path && path !== '/' ? `#/file?path=${encodeURIComponent(path)}` : '#/file';
    if (location.hash !== hash) history.replaceState(null, '', hash);
  } catch (error) {
    fp.error = error.message || '无法打开目录';
    fp.entries = [];
    fp.selected.clear();
    toast(fp.error, 'error');
  }
  fp.loading = false;
  updateRoots();
  updateMain();
}

function updateRoots() {
  const container = document.getElementById('fp-roots');
  if (container) container.innerHTML = rootsHTML();
  bindRoots();
}

function updateMain() {
  const container = document.getElementById('fp-main');
  if (!container) return;
  container.innerHTML = mainHTML();
  bindMain();
}

function updateSelectionUI() {
  const bar = document.getElementById('fp-selection');
  const count = document.getElementById('fp-selected-count');
  if (!bar || !count) return;
  bar.classList.toggle('hidden', fp.selected.size === 0);
  count.textContent = `${fp.selected.size} 项已选`;
}

/* ---------------- 绑定 ---------------- */

function bindRoots() {
  document.querySelectorAll('[data-root]').forEach((button) => {
    button.addEventListener('click', () => {
      const path = button.dataset.root;
      if (path === fp.path) return;
      loadDirectory(path);
    });
  });
}

function bindMain() {
  const main = document.getElementById('fp-main');
  if (!main) return;

  main.querySelectorAll('[data-crumb]').forEach((button) => {
    button.addEventListener('click', () => loadDirectory(button.dataset.crumb));
  });
  main.querySelectorAll('[data-fp-open]').forEach((element) => {
    element.addEventListener('click', (event) => {
      event.stopPropagation();
      const path = element.dataset.fpOpen;
      const entry = fp.entries.find((item) => item.path === path);
      if (!entry) return;
      if (entry.isDirectory) loadDirectory(path);
      else openPreview(entry);
    });
  });
  main.querySelectorAll('[data-fp-menu]').forEach((element) => {
    element.addEventListener('click', (event) => {
      event.stopPropagation();
      const entry = fp.entries.find((item) => item.path === element.dataset.fpMenu);
      if (entry) openActions(entry);
    });
  });
  main.querySelectorAll('[data-entry-path]').forEach((row) => {
    row.addEventListener('click', (event) => {
      if (event.target.closest('input, button, a, select, textarea')) return;
      const entry = fp.entries.find((item) => item.path === row.dataset.entryPath);
      if (!entry) return;
      if (entry.isDirectory) loadDirectory(entry.path);
      else openPreview(entry);
    });
    row.addEventListener('contextmenu', (event) => {
      event.preventDefault();
      const entry = fp.entries.find((item) => item.path === row.dataset.entryPath);
      if (entry) openActions(entry);
    });
  });
  main.querySelectorAll('[data-fp-select]').forEach((checkbox) => {
    checkbox.addEventListener('click', (event) => event.stopPropagation());
    checkbox.addEventListener('change', () => {
      const path = checkbox.dataset.fpSelect;
      if (checkbox.checked) fp.selected.add(path); else fp.selected.delete(path);
      const row = checkbox.closest('[data-entry-path]');
      if (row) row.classList.toggle('selected', checkbox.checked);
      updateSelectionUI();
    });
  });

  main.querySelector('[data-fp-up]')?.addEventListener('click', () => {
    if (fp.path === '/') return;
    loadDirectory(parentPath(fp.path));
  });
  main.querySelector('[data-fp-home]')?.addEventListener('click', () => loadDirectory('/'));
  main.querySelector('[data-fp-refresh]')?.addEventListener('click', () => loadDirectory(fp.path));
  main.querySelector('[data-fp-upload]')?.addEventListener('click', triggerUpload);
  main.querySelector('[data-fp-mkdir]')?.addEventListener('click', createFolder);
  main.querySelector('[data-fp-zip]')?.addEventListener('click', zipCurrent);
  main.querySelectorAll('[data-fp-view]').forEach((button) => {
    button.addEventListener('click', () => {
      fp.view = button.dataset.fpView;
      updateMain();
    });
  });
  main.querySelector('[data-fp-clear-selection]')?.addEventListener('click', () => {
    fp.selected.clear();
    updateMain();
  });
  main.querySelector('[data-fp-bulk-download]')?.addEventListener('click', bulkDownload);
  main.querySelector('[data-fp-bulk-move]')?.addEventListener('click', bulkMove);
  main.querySelector('[data-fp-bulk-delete]')?.addEventListener('click', bulkDelete);

  setupDragDrop();
  updateSelectionUI();
}

function bindShellExtras() {
  // 根目录按钮在 layout 首次渲染后需要绑定
  bindRoots();
}

/* ---------------- 动作 ---------------- */

function triggerUpload() {
  if (!isUser()) { toast('访客为只读权限', 'error'); return; }
  const input = document.createElement('input');
  input.type = 'file';
  input.multiple = true;
  input.className = 'hidden';
  document.body.appendChild(input);
  input.addEventListener('change', () => {
    const files = Array.from(input.files || []);
    input.remove();
    if (files.length) uploadFiles(files);
  });
  input.click();
}

function createFolder() {
  if (!isUser()) { toast('访客为只读权限', 'error'); return; }
  const dialog = modal({
    title: '新建文件夹',
    content: `<label class="field-label">文件夹名称</label><input id="mkdir-name" class="field" placeholder="例如：Backup" autofocus>`,
    footer: `<button class="btn btn-ghost" data-cancel>取消</button><button class="btn btn-primary" data-ok>创建</button>`
  });
  dialog.root.querySelector('[data-cancel]').addEventListener('click', dialog.close);
  const submit = async () => {
    const name = dialog.root.querySelector('#mkdir-name').value.trim();
    if (!name) { toast('请输入名称', 'error'); return; }
    try {
      await api.fileMkdir(joinPath(fp.path, name));
      dialog.close();
      toast('文件夹已创建', 'success');
      loadDirectory(fp.path);
    } catch (error) { toast(error.message, 'error'); }
  };
  dialog.root.querySelector('[data-ok]').addEventListener('click', submit);
  dialog.root.querySelector('#mkdir-name').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') submit();
  });
}

function openActions(entry) {
  const canWrite = isUser() && !entry.isReadOnly;
  const actions = [];
  actions.push(`<button class="btn btn-ghost w-full justify-start" data-act="preview">${icon('image', 'w-4 h-4')}预览</button>`);
  actions.push(`<button class="btn btn-ghost w-full justify-start" data-act="download">${icon('download', 'w-4 h-4')}下载</button>`);
  if (!entry.isDirectory) {
    actions.push(`<button class="btn btn-ghost w-full justify-start" data-act="share">${icon('share', 'w-4 h-4')}生成临时分享</button>`);
  }
  if (entry.isDirectory) {
    actions.push(`<button class="btn btn-ghost w-full justify-start" data-act="zip">${icon('archive', 'w-4 h-4')}ZIP 打包下载</button>`);
  }
  if (canWrite) {
    actions.push(`<button class="btn btn-ghost w-full justify-start" data-act="rename">${icon('edit', 'w-4 h-4')}重命名</button>`);
    actions.push(`<button class="btn btn-ghost w-full justify-start" data-act="move">${icon('move', 'w-4 h-4')}移动到…</button>`);
    actions.push(`<button class="btn btn-danger w-full justify-start" data-act="delete">${icon('trash', 'w-4 h-4')}删除</button>`);
  }
  const dialog = modal({
    title: entry.name,
    content: `<div class="text-[0.68rem] muted mono mb-4 truncate">${escapeHtml(entry.path)}</div>
              <div class="space-y-1.5">${actions.join('')}</div>`
  });
  dialog.root.querySelectorAll('[data-act]').forEach((button) => {
    button.addEventListener('click', () => {
      const action = button.dataset.act;
      dialog.close();
      if (action === 'preview') openPreview(entry);
      if (action === 'download') downloadEntry(entry);
      if (action === 'share') shareEntry(entry);
      if (action === 'zip') downloadZip(entry.path);
      if (action === 'rename') renameEntry(entry);
      if (action === 'move') moveEntry(entry);
      if (action === 'delete') deleteEntry(entry);
    });
  });
}

async function openPreview(entry) {
  if (entry.isDirectory) { loadDirectory(entry.path); return; }
  const kind = String(entry.kind || 'file');
  const inlineURL = api.downloadFileURL(entry.path, true);
  const imagePreviewURL = api.filePreviewURL(entry.path, 2048);

  if (kind === 'text') {
    const dialog = modal({
      title: entry.name,
      wide: true,
      content: `<div class="text-[0.72rem] muted">正在读取文本…</div>`,
      footer: `<button class="btn btn-ghost" data-dl>${icon('download', 'w-3.5 h-3.5')}下载</button><button class="btn btn-primary" data-close>关闭</button>`
    });
    dialog.root.querySelector('[data-close]').addEventListener('click', dialog.close);
    dialog.root.querySelector('[data-dl]').addEventListener('click', () => downloadEntry(entry));
    try {
      const response = await api.raw('/api/file/download?path=' + encodeURIComponent(entry.path) + '&inline=1', {
        raw: true,
        headers: { Range: 'bytes=0-262143' }
      });
      const text = await response.text();
      dialog.content.innerHTML = `<pre class="code-block max-h-[70vh] overflow-auto">${escapeHtml(text.slice(0, 400000))}</pre>`;
    } catch (error) {
      dialog.content.innerHTML = `<div class="text-[0.75rem]" style="color:var(--danger)">${escapeHtml(error.message)}</div>`;
    }
    return;
  }

  if (kind === 'image' || kind === 'pdf' || kind === 'video' || kind === 'audio') {
    let content = '';
    if (kind === 'image') {
      content = `
        <div class="text-center">
          <img src="${imagePreviewURL}" alt="${escapeHtml(entry.name)}" class="max-h-[72vh] mx-auto rounded-xl object-contain">
          <div class="text-[0.66rem] muted mt-2">HEIC/HEIF 会自动转成 JPEG；如果仍无法显示，请下载原文件。</div>
        </div>`;
    }
    if (kind === 'video') {
      content = `
        <video src="${inlineURL}" controls autoplay playsinline class="max-h-[72vh] w-full rounded-xl bg-black"></video>
        <div class="text-[0.66rem] muted mt-2">浏览器不支持 MOV/HEVC 时请下载后用系统播放器打开。</div>`;
    }
    if (kind === 'audio') content = `<div class="p-6"><audio src="${inlineURL}" controls class="w-full"></audio><div class="text-center mt-4">${escapeHtml(entry.name)}</div></div>`;
    if (kind === 'pdf') content = `<iframe src="${inlineURL}" class="w-full h-[72vh] rounded-xl border-0" title="${escapeHtml(entry.name)}"></iframe>`;
    const dialog = modal({
      title: entry.name,
      wide: true,
      plain: true,
      content,
      footer: `<button class="btn btn-ghost" data-dl>${icon('download', 'w-3.5 h-3.5')}下载</button><button class="btn btn-primary" data-close>关闭</button>`
    });
    dialog.root.querySelector('[data-close]').addEventListener('click', dialog.close);
    dialog.root.querySelector('[data-dl]').addEventListener('click', () => downloadEntry(entry));
    return;
  }

  toast('该类型暂不支持网页预览，请下载后查看', 'info');
}

function downloadEntry(entry) {
  const anchor = document.createElement('a');
  anchor.href = api.downloadFileURL(entry.path, false);
  anchor.download = entry.name;
  anchor.click();
  toast('已开始下载', 'success');
}

function downloadZip(path) {
  const anchor = document.createElement('a');
  anchor.href = api.zipURL(path);
  anchor.click();
}

function zipCurrent() {
  if (fp.path === '/') { toast('请先进入一个目录再打包', 'error'); return; }
  downloadZip(fp.path);
}

function shareEntry(entry) {
  if (!isUser()) { toast('访客不能创建分享', 'error'); return; }
  const dialog = modal({
    title: '临时分享 · ' + entry.name,
    content: `
      <label class="field-label">有效期（分钟）</label>
      <input id="share-expiry" class="field mb-4" type="number" min="1" max="10080" value="60">
      <label class="field-label">分享密码（可选）</label>
      <input id="share-password" class="field" type="text" placeholder="留空表示无密码">
      <div class="field-hint">链接只指向这一个文件；到期后自动失效。</div>
      <div id="share-result" class="mt-4 hidden">
        <div class="field-label">分享链接</div>
        <div class="flex gap-2">
          <input id="share-url" class="field mono" readonly>
          <button class="btn btn-primary btn-sm" data-copy-link>${icon('copy', 'w-3.5 h-3.5')}</button>
        </div>
        <div class="field-hint">链接会带上当前局域网/公网地址；如果隧道地址变化，请重新生成。</div>
      </div>`,
    footer: `<button class="btn btn-ghost" data-close>关闭</button><button class="btn btn-primary" data-create>生成链接</button>`
  });
  dialog.root.querySelector('[data-close]').addEventListener('click', dialog.close);
  dialog.root.querySelector('[data-create]').addEventListener('click', async () => {
    const expiry = Number(dialog.root.querySelector('#share-expiry').value || 60);
    const password = dialog.root.querySelector('#share-password').value || '';
    try {
      const data = await api.fileShare(entry.path, expiry, password);
      const url = data.share.url;
      dialog.root.querySelector('#share-result').classList.remove('hidden');
      dialog.root.querySelector('#share-url').value = url;
      dialog.root.querySelector('[data-copy-link]').onclick = () => copyText(url);
      toast('分享链接已生成', 'success');
    } catch (error) { toast(error.message, 'error'); }
  });
}

function renameEntry(entry) {
  const dialog = modal({
    title: '重命名',
    content: `<label class="field-label">新名称</label><input id="rename-name" class="field" value="${escapeAttr(entry.name)}">`,
    footer: `<button class="btn btn-ghost" data-cancel>取消</button><button class="btn btn-primary" data-ok>保存</button>`
  });
  dialog.root.querySelector('[data-cancel]').addEventListener('click', dialog.close);
  dialog.root.querySelector('[data-ok]').addEventListener('click', async () => {
    const name = dialog.root.querySelector('#rename-name').value.trim();
    if (!name) { toast('名称不能为空', 'error'); return; }
    try {
      await api.fileRename(entry.path, name);
      dialog.close();
      toast('已重命名', 'success');
      loadDirectory(fp.path);
    } catch (error) { toast(error.message, 'error'); }
  });
}

function moveEntry(entry) {
  const dialog = modal({
    title: '移动到',
    content: `
      <label class="field-label">目标目录</label>
      <input id="move-dest" class="field" value="${escapeAttr(parentPath(entry.path))}" placeholder="/shared/目标目录">
      <div class="field-hint">请输入完整虚拟路径，例如 /shared/Archive。暂不支持跨挂载根目录移动。</div>
      <div class="mt-3 flex flex-wrap gap-1.5">
        ${fp.roots.map((root) => `<button class="btn btn-ghost btn-sm" data-dest="${escapeAttr(root.path)}">${escapeHtml(root.name)}</button>`).join('')}
      </div>`,
    footer: `<button class="btn btn-ghost" data-cancel>取消</button><button class="btn btn-primary" data-ok>移动</button>`
  });
  dialog.root.querySelector('[data-cancel]').addEventListener('click', dialog.close);
  dialog.root.querySelectorAll('[data-dest]').forEach((button) => {
    button.addEventListener('click', () => {
      dialog.root.querySelector('#move-dest').value = button.dataset.dest;
    });
  });
  dialog.root.querySelector('[data-ok]').addEventListener('click', async () => {
    const destination = dialog.root.querySelector('#move-dest').value.trim();
    if (!destination) { toast('请输入目标目录', 'error'); return; }
    try {
      await api.fileMove(entry.path, destination);
      dialog.close();
      toast('已移动', 'success');
      loadDirectory(fp.path);
    } catch (error) { toast(error.message, 'error'); }
  });
}

async function deleteEntry(entry) {
  const ok = await confirmDialog('删除？', `确定删除「${entry.name}」？文件夹会连同内容一起删除。`, '删除');
  if (!ok) return;
  try {
    await api.fileDelete(entry.path);
    toast('已删除', 'success');
    loadDirectory(fp.path);
  } catch (error) { toast(error.message, 'error'); }
}

function selectedEntries() {
  return fp.entries.filter((entry) => fp.selected.has(entry.path));
}

async function bulkDownload() {
  const entries = selectedEntries();
  if (!entries.length) return;
  for (const entry of entries) {
    if (entry.isDirectory) downloadZip(entry.path);
    else downloadEntry(entry);
    await new Promise((resolve) => setTimeout(resolve, 350));
  }
}

function bulkMove() {
  const entries = selectedEntries();
  if (!entries.length) return;
  const dialog = modal({
    title: `移动 ${entries.length} 项`,
    content: `<label class="field-label">目标目录</label><input id="bulk-dest" class="field" placeholder="/shared/Archive">`,
    footer: `<button class="btn btn-ghost" data-cancel>取消</button><button class="btn btn-primary" data-ok>移动</button>`
  });
  dialog.root.querySelector('[data-cancel]').addEventListener('click', dialog.close);
  dialog.root.querySelector('[data-ok]').addEventListener('click', async () => {
    const destination = dialog.root.querySelector('#bulk-dest').value.trim();
    if (!destination) { toast('请输入目标目录', 'error'); return; }
    try {
      for (const entry of entries) {
        await api.fileMove(entry.path, destination);
      }
      dialog.close();
      toast('已移动', 'success');
      loadDirectory(fp.path);
    } catch (error) { toast(error.message, 'error'); }
  });
}

async function bulkDelete() {
  const entries = selectedEntries();
  if (!entries.length) return;
  const ok = await confirmDialog('删除所选？', `将删除 ${entries.length} 项，文件夹会连同内容一起删除。`, '删除');
  if (!ok) return;
  try {
    for (const entry of entries) {
      await api.fileDelete(entry.path);
    }
    toast('已删除', 'success');
    loadDirectory(fp.path);
  } catch (error) { toast(error.message, 'error'); }
}

/* ---------------- 上传 ---------------- */

function setupDragDrop() {
  const main = document.getElementById('fp-main');
  if (!main || main.dataset.dragBound === '1') return;
  main.dataset.dragBound = '1';
  let depth = 0;

  main.addEventListener('dragenter', (event) => {
    if (!isUser()) return;
    event.preventDefault();
    depth += 1;
    main.classList.add('ring-2');
    main.style.outlineColor = 'var(--accent)';
  });
  main.addEventListener('dragover', (event) => {
    if (!isUser()) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
  });
  main.addEventListener('dragleave', (event) => {
    if (!isUser()) return;
    depth -= 1;
    if (depth <= 0) { depth = 0; main.classList.remove('ring-2'); }
  });
  main.addEventListener('drop', (event) => {
    if (!isUser()) return;
    event.preventDefault();
    depth = 0;
    main.classList.remove('ring-2');
    const files = Array.from(event.dataTransfer.files || []);
    if (files.length) uploadFiles(files);
  });
}

async function uploadFiles(files) {
  if (fp.uploading) { toast('已有上传任务正在进行', 'error'); return; }
  fp.uploading = true;

  const rows = files.map((file, index) => `
    <div class="flex items-center gap-3 py-2" data-upload-row="${index}">
      <div class="file-icon">${icon('upload', 'w-4 h-4')}</div>
      <div class="min-w-0 flex-1">
        <div class="text-[0.76rem] font-medium truncate">${escapeHtml(file.name)}</div>
        <div class="progress-track mt-1.5"><div class="progress-fill" style="width:0%"></div></div>
      </div>
      <div class="text-[0.64rem] muted mono" data-upload-status>等待</div>
    </div>`).join('');

  const dialog = modal({
    title: `上传 ${files.length} 个文件`,
    content: `<div class="text-[0.68rem] muted mb-2">目标目录 <span class="mono">${escapeHtml(fp.path)}</span></div>${rows}`,
    footer: `<button class="btn btn-ghost" data-close disabled>上传中…</button>`
  });
  const closeButton = dialog.root.querySelector('[data-close]');
  closeButton.addEventListener('click', () => dialog.close());

  let completed = 0;
  for (let index = 0; index < files.length; index += 1) {
    const file = files[index];
    const row = dialog.root.querySelector(`[data-upload-row="${index}"]`);
    const fill = row.querySelector('.progress-fill');
    const status = row.querySelector('[data-upload-status]');
    const target = joinPath(fp.path, file.name);
    try {
      const entry = await uploadSingleFile(file, target, (loaded) => {
        const percent = file.size ? Math.min(99, Math.round((loaded / file.size) * 100)) : 99;
        fill.style.width = percent + '%';
        status.textContent = `${percent}%`;
      });
      fill.style.width = '100%';
      status.textContent = '完成';
      completed += 1;
      if (entry && entry.entry) {
        // 保持后续提示
      }
    } catch (error) {
      status.textContent = '失败';
      status.style.color = 'var(--danger)';
      toast(`${file.name} 上传失败：${error.message}`, 'error', 6000);
    }
  }

  fp.uploading = false;
  closeButton.disabled = false;
  closeButton.textContent = '关闭';
  if (completed > 0) {
    toast(`${completed} 个文件上传完成`, 'success');
    loadDirectory(fp.path);
  }
}

async function uploadSingleFile(file, targetPath, onProgress) {
  const chunkThreshold = 4 * 1024 * 1024;
  if (file.size <= chunkThreshold) {
    return api.uploadRaw(targetPath, file, onProgress);
  }

  const session = await api.uploadInit(targetPath, file.size);
  const chunkSize = Number(session.chunkSize) || (8 * 1024 * 1024);
  const totalChunks = Number(session.totalChunks) || Math.ceil(file.size / chunkSize);
  let uploadedBefore = 0;

  const uploadChunk = async (index) => {
    const start = index * chunkSize;
    const end = Math.min(file.size, start + chunkSize);
    const blob = file.slice(start, end);
    await api.uploadChunk(session.uploadId, index, blob, (loaded) => {
      if (onProgress) onProgress(uploadedBefore + loaded, end - start);
    });
    uploadedBefore += (end - start);
    if (onProgress) onProgress(uploadedBefore, end - start);
  };

  let missing = null;
  try {
    for (let index = 0; index < totalChunks; index += 1) {
      await uploadChunk(index);
    }
  } catch (error) {
    // 断点续传：查询服务端已收到的分片，补传缺失部分
    try {
      const status = await api.uploadStatus(session.uploadId);
      missing = status.missing || [];
      uploadedBefore = 0;
      for (const index of missing) {
        await uploadChunk(index);
      }
    } catch (retryError) {
      throw error;
    }
  }

  return api.uploadComplete(session.uploadId);
}
