// PitHub 前端入口：登录、路由、控制台。

import { api, state, setToken, getToken } from './api.js';
import {
  initTheme, icon, escapeHtml, formatBytes, formatDate, roleLabel,
  toast, copyText, modal, confirmDialog, themeIcon, cycleTheme
} from './ui.js';
import { renderShell } from './shell.js';
import { renderFilePit } from './filepit.js';
import { renderPhoto } from './photo.js';
import { renderClip } from './clip.js';
import { renderDash } from './dash.js';
import { renderLogs } from './logs.js';
import { renderSettings } from './settings.js';

const ROUTES = {
  dashboard: renderDashboard,
  file: renderFilePit,
  photo: renderPhoto,
  clip: renderClip,
  dash: renderDash,
  logs: renderLogs,
  settings: renderSettings
};

let qrObjectURL = null;
let dashboardTimer = null;

function isAdmin() { return state.auth && state.auth.role === 'admin'; }
function isUser() { return state.auth && (state.auth.role === 'user' || state.auth.role === 'admin'); }

function currentRoute() {
  const raw = (location.hash || '#/dashboard').replace(/^#\//, '');
  const key = raw.split('?')[0];
  return key || 'dashboard';
}

function route() {
  clearInterval(dashboardTimer);
  dashboardTimer = null;
  const key = currentRoute();

  if (!state.auth || !state.auth.authenticated) {
    renderLogin();
    return;
  }

  if (key === 'login') {
    location.hash = '#/dashboard';
    return;
  }

  const renderer = ROUTES[key];
  if (!renderer) {
    location.hash = '#/dashboard';
    return;
  }
  state.route = key;
  renderer();
}

async function loadCore() {
  const [status, pluginData] = await Promise.all([api.status(), api.plugins()]);
  state.status = status;
  state.plugins = pluginData.plugins || [];
}

/* ---------------- 登录 ---------------- */

function renderLogin(errorMessage = '') {
  const auth = state.auth || {};
  const guestEnabled = auth.guestEnabled !== false;
  let role = guestEnabled ? 'guest' : 'user';

  document.getElementById('app').innerHTML = `
    <div class="login-bg">
      <div class="login-orb w-[420px] h-[420px] -translate-x-[30vw] -translate-y-[28vh]" style="background:#2d5bb8"></div>
      <div class="login-orb w-[360px] h-[360px] translate-x-[34vw] translate-y-[30vh]" style="background:#1b3a6d"></div>
      <button class="btn btn-ghost btn-icon absolute right-4 top-4 z-10" data-theme-toggle aria-label="切换外观">${themeIcon()}</button>
      <div class="login-card animate-fade-up">
        <div class="flex items-center gap-3 mb-6">
          <div class="w-11 h-11 rounded-2xl flex items-center justify-center" style="background:var(--accent-soft);color:var(--accent)">
            ${icon('server', 'w-5 h-5')}
          </div>
          <div>
            <div class="text-xl font-bold tracking-tight">PitHub</div>
            <div class="muted" style="font-size:.64rem">家庭私有微型服务器</div>
          </div>
          <span class="badge badge-accent ml-auto">v1.0</span>
        </div>

        <div class="mb-2 text-[0.78rem] font-semibold">选择登录身份</div>
        <div class="role-segment mb-5">
          <button class="role-option ${role === 'guest' ? 'active' : ''}" data-role="guest" ${guestEnabled ? '' : 'disabled style="opacity:.35"'}>访客</button>
          <button class="role-option ${role === 'user' ? 'active' : ''}" data-role="user">用户</button>
          <button class="role-option ${role === 'admin' ? 'active' : ''}" data-role="admin">管理员</button>
        </div>

        <div id="password-wrap" class="mb-4 ${role === 'guest' ? 'hidden' : ''}">
          <label class="field-label" for="login-password">访问密码</label>
          <input id="login-password" class="field" type="password" autocomplete="current-password" placeholder="输入密码">
          <div class="field-hint">管理员密码与普通用户密码可以不同；访客默认只读。</div>
        </div>

        <label class="flex items-center gap-2 text-[0.74rem] muted mb-5 select-none">
          <input id="login-remember" type="checkbox" checked class="accent-checkbox">
          记住会话（浏览器重启后仍保持登录）
        </label>

        <div id="login-error" class="text-[0.72rem] mb-4" style="color:var(--danger)">${escapeHtml(errorMessage)}</div>

        <button id="login-submit" class="btn btn-primary btn-lg w-full">进入控制台</button>

        <div class="mt-5 text-[0.66rem] leading-relaxed" style="color:var(--muted-2)">
          默认密码是 <span class="mono">pithub</span>，首次登录后请到「设置」修改。
          所有照片、文件与剪贴内容只保存在这台 iPhone 上。
        </div>
      </div>
    </div>`;

  const app = document.getElementById('app');
  app.querySelectorAll('[data-theme-toggle]').forEach((button) => {
    button.addEventListener('click', () => {
      cycleTheme();
      app.querySelectorAll('[data-theme-toggle]').forEach((item) => {
        item.innerHTML = themeIcon();
      });
    });
  });

  const passwordWrap = document.getElementById('password-wrap');
  const passwordInput = document.getElementById('login-password');

  app.querySelectorAll('[data-role]').forEach((button) => {
    button.addEventListener('click', () => {
      if (button.disabled) return;
      role = button.dataset.role;
      app.querySelectorAll('[data-role]').forEach((item) => item.classList.toggle('active', item === button));
      passwordWrap.classList.toggle('hidden', role === 'guest');
      if (role !== 'guest') passwordInput.focus();
    });
  });

  const submit = async () => {
    const button = document.getElementById('login-submit');
    const errorBox = document.getElementById('login-error');
    errorBox.textContent = '';
    button.disabled = true;
    button.textContent = '正在登录…';
    try {
      const remember = document.getElementById('login-remember').checked;
      const data = await api.login(role, role === 'guest' ? '' : passwordInput.value, remember);
      setToken(data.token, remember);
      state.auth = {
        authenticated: true,
        role: data.role,
        defaultPassword: auth.defaultPassword,
        guestEnabled: auth.guestEnabled,
        serverName: auth.serverName
      };
      await loadCore();
      toast('登录成功', 'success');
      if (currentRoute() === 'login') location.hash = '#/dashboard';
      route();
    } catch (error) {
      errorBox.textContent = error.message || '登录失败';
      button.disabled = false;
      button.textContent = '进入控制台';
    }
  };

  document.getElementById('login-submit').addEventListener('click', submit);
  passwordInput.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') submit();
  });

  if (auth.defaultPassword) {
    toast('当前仍在使用默认密码 pithub，请尽快修改', 'error', 6000);
  }
}

/* ---------------- 控制台 ---------------- */

function statTile(title, value, iconName, options = {}) {
  return `
    <div class="stat-card">
      <div class="flex items-center gap-2">
        <span style="color:${options.color || 'var(--accent)'}">${icon(iconName, 'w-[0.95rem] h-[0.95rem]')}</span>
        <span class="text-[0.68rem] muted">${escapeHtml(title)}</span>
        ${options.copy ? `<button class="ml-auto muted-2 hover:text-[var(--accent)]" data-copy="${escapeHtml(options.copy)}" title="复制">${icon('copy', 'w-3.5 h-3.5')}</button>` : ''}
      </div>
      <div class="stat-value mono" ${options.id ? `id="${options.id}"` : ''}>${escapeHtml(value)}</div>
      ${options.hint ? `<div class="text-[0.62rem] muted-2 truncate">${escapeHtml(options.hint)}</div>` : ''}
    </div>`;
}

function pluginCard(plugin) {
  const enabled = Boolean(plugin.enabled);
  const admin = isAdmin();
  const canOpen = ['file', 'photo', 'clip', 'dash'].includes(plugin.id);
  return `
    <div class="plugin-card">
      <div class="flex items-start gap-3">
        <div class="icon-tile">${icon(plugin.id === 'file' ? 'folder' : plugin.id === 'photo' ? 'photo' : plugin.id === 'clip' ? 'clipboard' : 'bolt', 'w-5 h-5')}</div>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <div class="font-semibold text-[0.95rem] truncate">${escapeHtml(plugin.name)}</div>
            ${enabled ? '' : '<span class="badge">已禁用</span>'}
          </div>
          <div class="text-[0.7rem] muted leading-snug mt-1">${escapeHtml(plugin.summary)}</div>
        </div>
        <button class="switch ${enabled ? 'on' : ''} ${admin ? '' : 'disabled'}" data-plugin-toggle="${escapeHtml(plugin.id)}" aria-label="启停"></button>
      </div>
      <div class="flex items-center gap-2 mt-auto">
        <span class="mono text-[0.62rem] muted-2 truncate flex-1">${escapeHtml(plugin.prefix)}</span>
        ${canOpen ? `<a href="#/${plugin.id}" class="btn btn-ghost btn-sm">打开 ${icon('chevronRight', 'w-3.5 h-3.5')}</a>` : ''}
      </div>
    </div>`;
}

function renderDashboard() {
  const s = state.status || {};
  const tunnel = s.tunnel || {};
  const traffic = s.traffic || {};
  const plugins = state.plugins || [];
  const online = Boolean(s.online);
  const localURL = s.localURL || '';
  const tunnelURL = tunnel.active ? (tunnel.publicURL || '') : '';

  document.getElementById('app').removeAttribute('data-page');
  renderShell('dashboard', '控制台', `
    <div class="space-y-4 lg:space-y-5">
      <section class="glass p-5 lg:p-6 animate-fade-up">
        <div class="flex flex-col lg:flex-row lg:items-center gap-4">
          <div class="flex items-center gap-4 min-w-0">
            <div class="w-14 h-14 rounded-2xl flex items-center justify-center flex-none"
                 style="background:${online ? 'var(--accent-soft)' : 'var(--panel)'};color:${online ? 'var(--accent)' : 'var(--muted)'}">
              ${icon(online ? 'server' : 'warning', 'w-6 h-6')}
            </div>
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <span class="dot ${online ? 'dot-online' : 'dot-offline'}" id="live-dot"></span>
                <span class="text-[1.05rem] font-semibold" id="live-online">${online ? '服务运行中' : '服务已停止'}</span>
                <span class="badge ${online ? 'badge-success' : 'badge-warning'}">${online ? 'ONLINE' : 'OFFLINE'}</span>
              </div>
              <div class="mono text-[0.78rem] muted mt-1 truncate" id="live-url">${escapeHtml(localURL || '在 App 内点击启动服务')}</div>
              <div class="text-[0.65rem] muted-2 mt-1">Bonjour · _pithub._tcp · 端口 ${escapeHtml(s.port || '—')} · 运行 ${escapeHtml(formatUptime(s.uptime))}</div>
            </div>
          </div>
          <div class="flex items-center gap-2 lg:ml-auto flex-wrap">
            ${isAdmin() ? `<a href="#/settings" class="btn btn-ghost">${icon('settings', 'w-4 h-4')}设置</a>` : ''}
            ${isUser() ? `<a href="#/logs" class="btn btn-ghost">${icon('logs', 'w-4 h-4')}日志</a>` : ''}
            <button class="btn btn-primary" id="dash-refresh">${icon('refresh', 'w-4 h-4')}刷新状态</button>
          </div>
        </div>
        ${s.online ? '' : `<div class="mt-4 text-[0.72rem] rounded-xl px-3 py-2" style="background:rgba(232,180,90,.08);color:var(--warning)">
          服务处于停止状态，网页仍可浏览但不能读写数据。请打开 PitHub App 启动服务。
        </div>`}
      </section>

      <section class="grid grid-cols-2 xl:grid-cols-6 gap-3">
        ${statTile('局域网地址', localURL || '—', 'wifi', { copy: localURL, hint: s.lanHost || '' })}
        ${statTile('公网隧道', tunnel.active ? tunnelURL : (tunnel.message || '仅局域网'), 'globe', { color: tunnel.active ? 'var(--success)' : 'var(--muted)', copy: tunnel.active ? tunnelURL : '' })}
        ${statTile('当前连接', String(s.connections || 0), 'link', { id: 'live-connections' })}
        ${statTile('总流量', s.trafficText ? s.trafficText.total : formatBytes(traffic.total), 'dashboard', { id: 'live-traffic' })}
        ${statTile('局域网流量', s.trafficText ? s.trafficText.lan : formatBytes((traffic.lanIn || 0) + (traffic.lanOut || 0)), 'server', { color: 'var(--muted)' })}
        ${statTile('隧道流量', s.trafficText ? s.trafficText.tunnel : formatBytes((traffic.tunnelIn || 0) + (traffic.tunnelOut || 0)), 'globe', { color: 'var(--muted)' })}
      </section>

      <section class="grid lg:grid-cols-[minmax(0,1.25fr)_minmax(0,.75fr)] gap-4 ${isUser() ? '' : 'hidden'}">
        <div class="glass p-5">
          <div class="flex items-center gap-2 mb-4">
            <div class="section-title">外网隧道</div>
            <span class="badge ${tunnel.active ? 'badge-success' : ''}">${escapeHtml(tunnel.providerName || '仅局域网')}</span>
            <span class="ml-auto text-[0.68rem] ${tunnel.active ? 'accent' : 'muted'}">${escapeHtml(tunnel.message || '')}</span>
          </div>
          ${tunnelURL ? `<div class="glass-soft p-3 flex items-center gap-2 mb-3">
            <span class="dot dot-online"></span>
            <span class="mono text-[0.72rem] truncate flex-1">${escapeHtml(tunnelURL)}</span>
            <button class="btn btn-ghost btn-sm btn-icon" data-copy="${escapeHtml(tunnelURL)}">${icon('copy', 'w-3.5 h-3.5')}</button>
          </div>` : `<div class="glass-soft p-3 text-[0.72rem] leading-relaxed muted mb-3">
            Cloudflare / frp 需要外部连接器；Relay 模式可在设置里一键连接。iOS 沙盒不允许 App 启动外部二进制。
          </div>`}
          <div class="grid grid-cols-2 gap-3">
            <div class="glass-soft p-3">
              <div class="text-[0.65rem] muted mb-1">WebDAV 挂载点</div>
              <div class="mono text-[0.7rem] truncate">${escapeHtml((s.shareBaseURL || localURL || '') + '/webdav')}</div>
            </div>
            <div class="glass-soft p-3">
              <div class="text-[0.65rem] muted mb-1">上传上限</div>
              <div class="mono text-[0.7rem]">${escapeHtml(s.online ? 'FilePit 可配置' : '—')}</div>
            </div>
          </div>
        </div>

        <div class="glass p-5 flex flex-col items-center">
          <div class="flex items-center w-full gap-2 mb-3">
            <div class="section-title">扫码访问</div>
            <div class="ml-auto flex gap-1 p-1 rounded-xl" style="background:rgba(0,0,0,.16)">
              <button class="btn btn-sm ${tunnelURL ? '' : 'disabled'}" data-qr-mode="lan" id="qr-lan">局域网</button>
              <button class="btn btn-sm ${tunnelURL ? '' : 'disabled'}" data-qr-mode="tunnel" id="qr-tunnel">公网</button>
            </div>
          </div>
          <div class="w-[170px] h-[170px] rounded-2xl overflow-hidden flex items-center justify-center" style="background:var(--panel)">
            <img id="qr-img" alt="访问二维码" class="w-full h-full object-contain hidden">
            <span id="qr-hint" class="text-[0.68rem] muted text-center px-3">服务启动后生成</span>
          </div>
          <div class="mono text-[0.64rem] muted text-center mt-3 truncate w-full" id="qr-url">${escapeHtml(localURL || '')}</div>
        </div>
      </section>

      <section>
        <div class="flex items-center mb-3">
          <div class="section-title">插件</div>
          <span class="badge ml-2">${plugins.filter((p) => p.enabled).length} / ${plugins.length} 启用</span>
          <a href="#/settings" class="ml-auto text-[0.7rem] accent">管理插件与设置</a>
        </div>
        <div class="grid md:grid-cols-2 xl:grid-cols-4 gap-3">
          ${plugins.map(pluginCard).join('') || '<div class="glass p-5 text-sm muted">暂未加载插件列表</div>'}
        </div>
      </section>

      <section class="glass p-5">
        <div class="flex items-start gap-3">
          <div style="color:var(--warning)">${icon('warning', 'w-5 h-5')}</div>
          <div>
            <div class="text-[0.82rem] font-semibold">关于后台与锁屏</div>
            <div class="text-[0.7rem] muted leading-relaxed mt-1">
              iOS 会在锁屏或后台一段时间后挂起 App，HTTP 服务也会暂停。建议插电常驻、保持屏幕常亮，并在 App 设置里选择「锁屏尽量保活」。
              这是系统限制，PitHub 不会使用私有 API 绕过沙盒。
            </div>
          </div>
        </div>
      </section>
    </div>
  `);

  bindDashboard();
  startDashboardTimer();
  if (!isUser()) {
    // 访客只读：不加载二维码、不请求任何配置接口
    const guestNote = document.createElement('div');
    guestNote.className = 'glass p-4 text-[0.72rem]';
    guestNote.style.color = 'var(--muted)';
    guestNote.textContent = '访客只读模式：可以浏览共享文件与相册，不能上传、修改、查看设置或执行快捷指令。';
    document.querySelector('main')?.prepend(guestNote);
  }
}

function formatUptime(seconds) {
  const total = Math.max(0, Number(seconds) || 0);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  return hours > 0 ? `${hours}h ${minutes}m` : `${minutes}m`;
}

function bindDashboard() {
  const app = document.getElementById('app');
  app.querySelectorAll('[data-copy]').forEach((button) => {
    button.addEventListener('click', () => copyText(button.dataset.copy || ''));
  });

  app.querySelectorAll('[data-plugin-toggle]').forEach((button) => {
    button.addEventListener('click', async () => {
      if (!isAdmin()) { toast('只有管理员可以启停插件', 'error'); return; }
      const id = button.dataset.pluginToggle;
      const plugin = state.plugins.find((item) => item.id === id);
      if (!plugin) return;
      const next = !plugin.enabled;
      button.classList.add('disabled');
      try {
        if (next) await api.enablePlugin(id);
        else await api.disablePlugin(id);
        plugin.enabled = next;
        state.status = await api.status();
        toast(`${plugin.name} 已${next ? '启用' : '禁用'}`, 'success');
        renderDashboard();
      } catch (error) {
        toast(error.message, 'error');
        button.classList.remove('disabled');
      }
    });
  });

  document.getElementById('dash-refresh')?.addEventListener('click', async () => {
    try {
      await refreshStatus();
      toast('状态已刷新', 'success');
    } catch (error) {
      toast(error.message, 'error');
    }
  });

  let qrMode = 'lan';
  const setMode = (mode) => {
    qrMode = mode;
    const lan = document.getElementById('qr-lan');
    const tunnel = document.getElementById('qr-tunnel');
    if (lan) lan.className = `btn btn-sm ${mode === 'lan' ? 'btn-primary' : ''}`;
    if (tunnel) tunnel.className = `btn btn-sm ${mode === 'tunnel' ? 'btn-primary' : ''}`;
    loadQR(mode);
  };
  if (!isUser()) return;
  document.getElementById('qr-lan')?.addEventListener('click', () => setMode('lan'));
  document.getElementById('qr-tunnel')?.addEventListener('click', () => {
    if (!state.status?.tunnel?.publicURL) return;
    setMode('tunnel');
  });

  setMode('lan');
}

async function loadQR(mode) {
  const image = document.getElementById('qr-img');
  const hint = document.getElementById('qr-hint');
  const urlLabel = document.getElementById('qr-url');
  if (!image || !hint) return;
  const target = mode === 'tunnel' ? (state.status?.tunnel?.publicURL || '') : (state.status?.localURL || '');
  urlLabel.textContent = target || '';
  if (!target) {
    image.classList.add('hidden');
    hint.classList.remove('hidden');
    hint.textContent = mode === 'tunnel' ? '公网隧道未启用' : '服务启动后生成';
    return;
  }
  try {
    if (qrObjectURL) { URL.revokeObjectURL(qrObjectURL); qrObjectURL = null; }
    qrObjectURL = await api.qrURL(target);
    image.src = qrObjectURL;
    image.classList.remove('hidden');
    hint.classList.add('hidden');
  } catch {
    image.classList.add('hidden');
    hint.classList.remove('hidden');
    hint.textContent = '二维码生成失败';
  }
}

async function refreshStatus() {
  state.status = await api.status();
  const plugins = await api.plugins();
  state.plugins = plugins.plugins || [];
  renderDashboard();
}

function startDashboardTimer() {
  clearInterval(dashboardTimer);
  dashboardTimer = setInterval(async () => {
    if (state.route !== 'dashboard' || !state.auth?.authenticated) return;
    try {
      const status = await api.status();
      state.status = status;
      const connections = document.getElementById('live-connections');
      const traffic = document.getElementById('live-traffic');
      const online = document.getElementById('live-online');
      const dot = document.getElementById('live-dot');
      const url = document.getElementById('live-url');
      if (connections) connections.textContent = String(status.connections || 0);
      if (traffic) traffic.textContent = status.trafficText ? status.trafficText.total : formatBytes((status.traffic || {}).total);
      if (online) online.textContent = status.online ? '服务运行中' : '服务已停止';
      if (dot) dot.className = `dot ${status.online ? 'dot-online' : 'dot-offline'}`;
      if (url) url.textContent = status.localURL || '在 App 内点击启动服务';
    } catch {}
  }, 10000);
}

/* ---------------- 生命周期 ---------------- */

window.addEventListener('hashchange', route);

window.addEventListener('pithub-unauthorized', () => {
  state.auth = null;
  renderLogin('登录已过期，请重新登录');
});

window.addEventListener('pithub-logout', async () => {
  try { await api.logout(); } catch {}
  setToken(null);
  state.auth = null;
  state.status = null;
  state.plugins = [];
  location.hash = '#/login';
  renderLogin();
});

async function boot() {
  initTheme();
  try {
    const auth = await api.authStatus();
    state.auth = auth;
    if (auth.authenticated) {
      await loadCore();
      route();
    } else {
      renderLogin();
    }
  } catch (error) {
    state.auth = { authenticated: false, guestEnabled: true, defaultPassword: true };
    renderLogin('无法连接到服务：' + (error.message || '未知错误'));
  }
}

boot();
