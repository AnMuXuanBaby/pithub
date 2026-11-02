//
// 访问日志面板：分页、搜索、导出 JSON / TXT。
//

import { api, state } from './api.js';
import {
  icon, escapeHtml, formatBytes, formatDate, toast, confirmDialog, debounce, emptyState
} from './ui.js';
import { renderShell } from './shell.js';

const logs = {
  items: [],
  total: 0,
  offset: 0,
  limit: 50,
  q: '',
  method: '',
  tunnel: '',
  loading: false,
  error: ''
};

function isAdmin() { return state.auth && state.auth.role === 'admin'; }
function isUser() { return state.auth && (state.auth.role === 'user' || state.auth.role === 'admin'); }

export async function renderLogs() {
  renderShell('logs', '访问日志', layoutHTML());
  bind();
  await load(true);
}

function layoutHTML() {
  return `
    <div class="space-y-4">
      <section class="glass p-4">
        <div class="flex flex-wrap items-center gap-2">
          <div class="relative flex-1 min-w-[180px]">
            <span class="absolute left-3 top-1/2 -translate-y-1/2" style="color:var(--muted-2)">${icon('search', 'w-3.5 h-3.5')}</span>
            <input id="logs-search" class="field !pl-9" placeholder="搜索 IP / 路径 / 操作">
          </div>
          <select id="logs-method" class="field !w-auto !h-9 !text-[0.72rem]">
            <option value="">全部方法</option>
            <option>GET</option><option>POST</option><option>PUT</option><option>DELETE</option><option>PROPFIND</option>
          </select>
          <select id="logs-tunnel" class="field !w-auto !h-9 !text-[0.72rem]">
            <option value="">全部来源</option>
            <option value="1">隧道</option>
            <option value="0">局域网</option>
          </select>
          <button class="btn btn-ghost btn-sm" id="logs-refresh">${icon('refresh', 'w-3.5 h-3.5')}刷新</button>
          ${isAdmin() ? `
            <button class="btn btn-ghost btn-sm" id="logs-export-json">导出 JSON</button>
            <button class="btn btn-ghost btn-sm" id="logs-export-txt">导出 TXT</button>
            <button class="btn btn-danger btn-sm" id="logs-clear">${icon('trash', 'w-3.5 h-3.5')}清空</button>` : ''}
        </div>
        <div class="flex items-center gap-2 mt-3">
          <span class="badge" id="logs-total">—</span>
          <span class="text-[0.66rem] muted">最新在前 · 仅记录 API / WebDAV / 分享等操作</span>
        </div>
      </section>

      <section class="glass overflow-hidden">
        <div class="p-3" id="logs-list"></div>
        <div class="p-3 border-t flex items-center justify-between" style="border-color:var(--border)">
          <button class="btn btn-ghost btn-sm" id="logs-prev">${icon('chevronLeft', 'w-3.5 h-3.5')}上一页</button>
          <span class="text-[0.66rem] muted" id="logs-page">—</span>
          <button class="btn btn-ghost btn-sm" id="logs-next">下一页${icon('chevronRight', 'w-3.5 h-3.5')}</button>
        </div>
      </section>
    </div>`;
}

function bind() {
  document.getElementById('logs-refresh')?.addEventListener('click', () => load(true));
  document.getElementById('logs-search')?.addEventListener('input', debounce((event) => {
    logs.q = event.target.value.trim();
    load(true);
  }, 400));
  document.getElementById('logs-method')?.addEventListener('change', (event) => {
    logs.method = event.target.value;
    load(true);
  });
  document.getElementById('logs-tunnel')?.addEventListener('change', (event) => {
    logs.tunnel = event.target.value;
    load(true);
  });
  document.getElementById('logs-prev')?.addEventListener('click', () => {
    logs.offset = Math.max(0, logs.offset - logs.limit);
    load(false);
  });
  document.getElementById('logs-next')?.addEventListener('click', () => {
    if (logs.offset + logs.limit >= logs.total) return;
    logs.offset += logs.limit;
    load(false);
  });
  document.getElementById('logs-export-json')?.addEventListener('click', () => exportLogs('json'));
  document.getElementById('logs-export-txt')?.addEventListener('click', () => exportLogs('txt'));
  document.getElementById('logs-clear')?.addEventListener('click', async () => {
    const ok = await confirmDialog('清空访问日志？', '此操作不可恢复。', '清空');
    if (!ok) return;
    try {
      await api.clearLogs();
      toast('日志已清空', 'success');
      await load(true);
    } catch (error) { toast(error.message, 'error'); }
  });
}

async function load(reset) {
  if (reset) logs.offset = 0;
  logs.loading = true;
  renderList();
  try {
    const data = await api.logs(
      logs.offset,
      logs.limit,
      logs.q,
      logs.method,
      logs.tunnel === '' ? null : logs.tunnel
    );
    logs.items = data.items || [];
    logs.total = data.total || 0;
    logs.error = '';
  } catch (error) {
    logs.items = [];
    logs.total = 0;
    logs.error = error.message || '读取日志失败';
  }
  logs.loading = false;
  renderList();
  renderMeta();
}

function renderMeta() {
  const total = document.getElementById('logs-total');
  if (total) total.textContent = `共 ${logs.total} 条`;
  const page = document.getElementById('logs-page');
  const start = logs.total ? logs.offset + 1 : 0;
  const end = Math.min(logs.total, logs.offset + logs.limit);
  if (page) page.textContent = `${start}–${end} / ${logs.total}`;
  const prev = document.getElementById('logs-prev');
  const next = document.getElementById('logs-next');
  if (prev) prev.disabled = logs.offset <= 0;
  if (next) next.disabled = logs.offset + logs.limit >= logs.total;
}

function renderList() {
  const container = document.getElementById('logs-list');
  if (!container) return;
  if (!isUser()) {
    container.innerHTML = emptyState('需要用户或管理员权限', '访客无法查看访问日志');
    return;
  }
  if (logs.error) {
    container.innerHTML = emptyState(logs.error, '请确认服务在线');
    return;
  }
  if (logs.loading && !logs.items.length) {
    container.innerHTML = `<div class="p-6 text-center text-[0.72rem] muted">正在读取日志…</div>`;
    return;
  }
  if (!logs.items.length) {
    container.innerHTML = emptyState('暂无访问记录', '发生文件访问、WebDAV 或登录操作后会记录在这里');
    return;
  }

  container.innerHTML = `
    <div class="hidden md:grid grid-cols-[minmax(0,1.4fr)_minmax(0,2fr)_7rem_5rem] gap-3 px-3 py-2 text-[0.6rem] uppercase tracking-wide" style="color:var(--muted-2)">
      <div>时间</div><div>请求 / 操作</div><div>来源</div><div class="text-right">流量</div>
    </div>
    ${logs.items.map((entry) => `
      <div class="log-row">
        <div class="min-w-0">
          <div class="mono text-[0.66rem]">${escapeHtml(formatDate(entry.date))}</div>
          <div class="flex items-center gap-1.5 mt-1">
            <span class="badge ${entry.tunnel ? 'badge-warning' : ''}">${entry.tunnel ? '隧道' : '局域网'}</span>
            <span class="badge ${entry.status >= 400 ? 'badge-danger' : 'badge-success'}">${entry.status}</span>
          </div>
        </div>
        <div class="min-w-0 log-method">
          <div class="flex items-center gap-1.5 min-w-0">
            <span class="mono text-[0.66rem] accent flex-none">${escapeHtml(entry.method)}</span>
            <span class="mono text-[0.68rem] truncate">${escapeHtml(entry.path)}</span>
          </div>
          <div class="text-[0.6rem] muted mt-1 truncate">${escapeHtml(entry.action)} · ${escapeHtml(entry.role)}</div>
        </div>
        <div class="min-w-0">
          <div class="mono text-[0.66rem] truncate">${escapeHtml(entry.ip)}</div>
          <div class="text-[0.6rem] muted md:hidden mt-1">${escapeHtml(entry.method)} · ${escapeHtml(entry.action)}</div>
        </div>
        <div class="text-right text-[0.64rem] mono muted">
          ↑ ${escapeHtml(formatBytes(entry.bytesIn))}<br>↓ ${escapeHtml(formatBytes(entry.bytesOut))}
        </div>
      </div>`).join('')}`;
}

async function exportLogs(format) {
  try {
    await api.logsExport(format);
    toast('导出已开始', 'success');
  } catch (error) { toast(error.message, 'error'); }
}
