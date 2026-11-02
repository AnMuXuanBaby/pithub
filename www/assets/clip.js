//
// ClipHub 剪贴板面板：提交、搜索、标签、批量删除。
//

import { api, state } from './api.js';
import {
  icon, escapeHtml, formatBytes, formatDate, toast, modal, confirmDialog,
  copyText, debounce, emptyState
} from './ui.js';
import { renderShell } from './shell.js';

const clip = {
  items: [],
  tags: [],
  tag: '',
  query: '',
  selected: new Set(),
  error: ''
};

function isUser() { return state.auth && (state.auth.role === 'user' || state.auth.role === 'admin'); }

export async function renderClip() {
  renderShell('clip', 'ClipHub', layoutHTML());
  bindStatic();
  await load();
}

function layoutHTML() {
  return `
    <div class="space-y-4">
      <section class="glass p-5">
        <div class="flex items-center gap-2 mb-3">
          <div class="icon-tile">${icon('clipboard', 'w-5 h-5')}</div>
          <div>
            <div class="text-[0.92rem] font-semibold">提交剪贴内容</div>
            <div class="text-[0.66rem] muted">文字、图片或文件记录都会保存在本机</div>
          </div>
          <span class="badge ml-auto" id="clip-count">—</span>
        </div>
        <textarea id="clip-text" class="field" rows="4" placeholder="粘贴或输入要保存的内容…（Ctrl/⌘ + Enter 提交）"></textarea>
        <div class="flex flex-wrap items-center gap-2 mt-3">
          <input id="clip-tags" class="field !w-auto min-w-[200px] flex-1" placeholder="标签，用逗号分隔，例如 work, 灵感">
          <button class="btn btn-ghost btn-sm" id="clip-paste" ${isUser() ? '' : 'disabled'}>${icon('clipboard', 'w-3.5 h-3.5')}读取剪贴板</button>
          <button class="btn btn-primary" id="clip-submit" ${isUser() ? '' : 'disabled'}>${icon('plus', 'w-4 h-4')}保存</button>
        </div>
        <div class="field-hint">图片/文件可通过 HTTP API <span class="mono">POST /api/clip/blob</span> 推送；网页端以文本剪贴为主。</div>
      </section>

      <section class="glass overflow-hidden">
        <div class="p-4 border-b flex flex-wrap items-center gap-2" style="border-color:var(--border)">
          <div class="relative flex-1 min-w-[180px]">
            <span class="absolute left-3 top-1/2 -translate-y-1/2" style="color:var(--muted-2)">${icon('search', 'w-3.5 h-3.5')}</span>
            <input id="clip-search" class="field !pl-9" placeholder="搜索历史剪贴…">
          </div>
          <button class="btn btn-ghost btn-sm" id="clip-refresh">${icon('refresh', 'w-3.5 h-3.5')}刷新</button>
          ${isUser() ? `<button class="btn btn-danger btn-sm" id="clip-clear">${icon('trash', 'w-3.5 h-3.5')}清空</button>` : ''}
        </div>
        <div class="px-4 pt-3 flex flex-wrap gap-1.5" id="clip-tags-bar"></div>
        <div class="p-3" id="clip-list"></div>
      </section>
    </div>`;
}

function bindStatic() {
  const submit = async () => {
    if (!isUser()) { toast('访客不能写入剪贴板', 'error'); return; }
    const text = document.getElementById('clip-text').value.trim();
    if (!text) { toast('请输入内容', 'error'); return; }
    const tags = document.getElementById('clip-tags').value
      .split(',').map((tag) => tag.trim()).filter(Boolean);
    try {
      await api.clipPush(text, tags);
      document.getElementById('clip-text').value = '';
      document.getElementById('clip-tags').value = '';
      toast('已保存', 'success');
      await load();
    } catch (error) { toast(error.message, 'error'); }
  };

  document.getElementById('clip-submit')?.addEventListener('click', submit);
  document.getElementById('clip-text')?.addEventListener('keydown', (event) => {
    if ((event.metaKey || event.ctrlKey) && event.key === 'Enter') submit();
  });
  document.getElementById('clip-paste')?.addEventListener('click', async () => {
    try {
      const text = await navigator.clipboard.readText();
      document.getElementById('clip-text').value = text;
      toast('已读取剪贴板', 'success');
    } catch { toast('浏览器不允许读取剪贴板，请手动粘贴', 'error'); }
  });
  document.getElementById('clip-refresh')?.addEventListener('click', () => load());
  document.getElementById('clip-clear')?.addEventListener('click', async () => {
    const ok = await confirmDialog('清空剪贴历史？', '所有文字、图片与文件记录都会被删除。', '清空');
    if (!ok) return;
    try {
      await api.clipClear();
      toast('已清空', 'success');
      await load();
    } catch (error) { toast(error.message, 'error'); }
  });
  document.getElementById('clip-search')?.addEventListener('input', debounce((event) => {
    clip.query = event.target.value.trim();
    clip.selected.clear();
    loadItems();
  }, 350));
}

async function load() {
  await Promise.all([loadItems(), loadTags()]);
}

async function loadItems() {
  const container = document.getElementById('clip-list');
  if (!container) return;
  container.innerHTML = `<div class="p-6 text-center text-[0.75rem] muted">正在读取…</div>`;
  try {
    const data = await api.clipList(clip.query, clip.tag, 0, 100);
    clip.items = data.items || [];
    clip.selected.clear();
    clip.error = '';
    renderItems(data.total || clip.items.length);
  } catch (error) {
    clip.items = [];
    clip.error = error.message || '读取失败';
    renderItems(0);
  }
}

async function loadTags() {
  try {
    const data = await api.clipTags();
    clip.tags = data.tags || [];
  } catch {
    clip.tags = [];
  }
  renderTags();
}

function renderTags() {
  const bar = document.getElementById('clip-tags-bar');
  if (!bar) return;
  if (!clip.tags.length) { bar.innerHTML = ''; return; }
  bar.innerHTML = `
    <button class="badge ${clip.tag === '' ? 'badge-accent' : ''}" data-tag="">全部</button>
    ${clip.tags.map((item) => `<button class="badge ${clip.tag === item.tag ? 'badge-accent' : ''}" data-tag="${escapeHtml(item.tag)}">#${escapeHtml(item.tag)} · ${item.count}</button>`).join('')}`;
  bar.querySelectorAll('[data-tag]').forEach((button) => {
    button.addEventListener('click', () => {
      clip.tag = button.dataset.tag;
      renderTags();
      loadItems();
    });
  });
}

function renderItems(total) {
  const container = document.getElementById('clip-list');
  if (!container) return;
  const count = document.getElementById('clip-count');
  if (count) count.textContent = `${total} 条`;

  if (clip.error) {
    container.innerHTML = emptyState(clip.error, '请确认 ClipHub 插件已启用');
    return;
  }
  if (!clip.items.length) {
    container.innerHTML = emptyState('还没有剪贴记录', '提交第一条内容试试');
    return;
  }

  container.innerHTML = `
    ${isUser() ? `<div class="flex items-center gap-2 px-2 pb-2">
      <button class="btn btn-ghost btn-sm" id="clip-select-all">全选</button>
      <span class="text-[0.66rem] muted" id="clip-selected-label">0 项已选</span>
      <button class="btn btn-danger btn-sm ml-auto" id="clip-bulk-delete" disabled>${icon('trash', 'w-3.5 h-3.5')}删除所选</button>
    </div>` : ''}
    <div class="space-y-1.5">
      ${clip.items.map((item) => itemHTML(item)).join('')}
    </div>`;

  container.querySelectorAll('[data-clip-select]').forEach((checkbox) => {
    checkbox.addEventListener('change', () => {
      const id = checkbox.dataset.clipSelect;
      if (checkbox.checked) clip.selected.add(id); else clip.selected.delete(id);
      updateSelection();
    });
  });
  container.querySelectorAll('[data-clip-copy]').forEach((button) => {
    button.addEventListener('click', () => {
      const item = clip.items.find((entry) => entry.id === button.dataset.clipCopy);
      if (item && item.text) copyText(item.text);
    });
  });
  container.querySelectorAll('[data-clip-delete]').forEach((button) => {
    button.addEventListener('click', async () => {
      const item = clip.items.find((entry) => entry.id === button.dataset.clipDelete);
      if (!item) return;
      const ok = await confirmDialog('删除这条记录？', item.text || item.filename, '删除');
      if (!ok) return;
      try {
        await api.clipDelete(item.id);
        toast('已删除', 'success');
        await load();
      } catch (error) { toast(error.message, 'error'); }
    });
  });
  container.querySelectorAll('[data-clip-open]').forEach((button) => {
    button.addEventListener('click', () => {
      const item = clip.items.find((entry) => entry.id === button.dataset.clipOpen);
      if (item) openBlobPreview(item);
    });
  });
  container.querySelectorAll('[data-tag-link]').forEach((button) => {
    button.addEventListener('click', (event) => {
      event.stopPropagation();
      clip.tag = button.dataset.tagLink;
      renderTags();
      loadItems();
    });
  });
  container.querySelector('#clip-select-all')?.addEventListener('click', () => {
    const allSelected = clip.items.every((item) => clip.selected.has(item.id));
    clip.selected = allSelected ? new Set() : new Set(clip.items.map((item) => item.id));
    container.querySelectorAll('[data-clip-select]').forEach((checkbox) => {
      checkbox.checked = clip.selected.has(checkbox.dataset.clipSelect);
    });
    updateSelection();
  });
  container.querySelector('#clip-bulk-delete')?.addEventListener('click', async () => {
    const ok = await confirmDialog('删除所选？', `将删除 ${clip.selected.size} 条剪贴记录。`, '删除');
    if (!ok) return;
    try {
      for (const id of Array.from(clip.selected)) {
        await api.clipDelete(id);
      }
      toast('已删除', 'success');
      await load();
    } catch (error) { toast(error.message, 'error'); }
  });
}

function updateSelection() {
  const label = document.getElementById('clip-selected-label');
  const button = document.getElementById('clip-bulk-delete');
  if (label) label.textContent = `${clip.selected.size} 项已选`;
  if (button) button.disabled = clip.selected.size === 0;
}

function itemHTML(item) {
  const blob = item.hasBlob ? api.clipBlobURL(item.id) : '';
  const preview = item.kind === 'image'
    ? `<button data-clip-open="${escapeHtml(item.id)}" class="block w-16 h-16 rounded-lg overflow-hidden flex-none" style="background:var(--panel-strong)">
         <img src="${blob}" class="w-full h-full object-cover" loading="lazy" alt="">
       </button>`
    : `<div class="file-icon flex-none">${icon(item.kind === 'file' ? 'file' : 'text', 'w-4 h-4')}</div>`;

  return `
    <div class="file-row !items-start">
      ${isUser() ? `<input type="checkbox" data-clip-select="${escapeHtml(item.id)}" class="mt-1.5 w-3.5 h-3.5 accent-[var(--accent)]">` : ''}
      ${preview}
      <div class="min-w-0 flex-1">
        <div class="text-[0.78rem] leading-relaxed whitespace-pre-wrap break-words ${item.kind === 'text' ? '' : 'font-medium'}">
          ${item.kind === 'text' ? escapeHtml(item.text) : escapeHtml(item.filename)}
        </div>
        <div class="flex flex-wrap items-center gap-1.5 mt-1.5">
          <span class="text-[0.6rem] muted">${escapeHtml(formatDate(item.createdAt))}</span>
          <span class="text-[0.6rem] muted-2">${escapeHtml(item.source || '')}</span>
          <span class="text-[0.6rem] muted-2">${escapeHtml(formatBytes(item.size))}</span>
          ${(item.tags || []).map((tag) => `<button class="badge" data-tag-link="${escapeHtml(tag)}">#${escapeHtml(tag)}</button>`).join('')}
        </div>
      </div>
      <div class="flex items-center gap-1 flex-none">
        ${item.kind === 'text' ? `<button class="btn btn-ghost btn-icon btn-sm" data-clip-copy="${escapeHtml(item.id)}" title="复制">${icon('copy', 'w-3.5 h-3.5')}</button>` : ''}
        ${item.hasBlob ? `<a class="btn btn-ghost btn-icon btn-sm" href="${blob}" download="${escapeHtml(item.filename)}" title="下载">${icon('download', 'w-3.5 h-3.5')}</a>` : ''}
        ${isUser() ? `<button class="btn btn-ghost btn-icon btn-sm" data-clip-delete="${escapeHtml(item.id)}" title="删除">${icon('trash', 'w-3.5 h-3.5')}</button>` : ''}
      </div>
    </div>`;
}

function openBlobPreview(item) {
  if (!item.hasBlob) return;
  const url = api.clipBlobURL(item.id);
  const content = item.kind === 'image'
    ? `<img src="${url}" alt="" class="max-h-[72vh] w-full object-contain rounded-xl bg-black">`
    : `<div class="text-center"><a class="btn btn-primary" href="${url}" download="${escapeHtml(item.filename)}">下载文件</a></div>`;
  const dialog = modal({ title: item.filename || '剪贴内容', content, wide: true, plain: true });
  dialog.content.querySelectorAll('img').forEach((image) => {
    image.addEventListener('click', () => dialog.close());
  });
}
