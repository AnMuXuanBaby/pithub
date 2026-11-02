// 页面外壳：侧边栏 / 移动端导航 / 顶栏。

import { state } from './api.js';
import { icon, escapeHtml, roleLabel, themeIcon, cycleTheme } from './ui.js';

const BASE_NAV = [
  { key: 'dashboard', href: '#/dashboard', label: '控制台', icon: 'dashboard' },
  { key: 'file', href: '#/file', label: 'FilePit', icon: 'folder', plugin: 'file' },
  { key: 'photo', href: '#/photo', label: 'PhotoNode', icon: 'photo', plugin: 'photo' },
  { key: 'clip', href: '#/clip', label: 'ClipHub', icon: 'clipboard', plugin: 'clip' },
  { key: 'dash', href: '#/dash', label: 'DashLink', icon: 'bolt', plugin: 'dash' },
  { key: 'logs', href: '#/logs', label: '访问日志', icon: 'logs' },
  { key: 'settings', href: '#/settings', label: '设置', icon: 'settings' }
];

function pluginDescriptor(id) {
  return (state.plugins || []).find((plugin) => plugin.id === id) || null;
}

function navItems() {
  return BASE_NAV.map((item) => {
    if (!item.plugin) return item;
    const descriptor = pluginDescriptor(item.plugin);
    return {
      ...item,
      enabled: descriptor ? descriptor.enabled : false,
      exists: Boolean(descriptor)
    };
  });
}

function navLink(item, active, compact = false) {
  const isActive = active === item.key;
  const disabled = item.plugin && !item.exists;
  const off = item.plugin && item.exists && !item.enabled;
  return `
    <a href="${item.href}" class="nav-link ${isActive ? 'active' : ''} ${disabled ? 'opacity-40' : ''}">
      <span class="nav-icon">${icon(item.icon, 'w-[1.1rem] h-[1.1rem]')}</span>
      <span class="flex-1 truncate">${escapeHtml(item.label)}</span>
      ${off ? '<span class="dot dot-offline" title="已禁用"></span>' : ''}
    </a>`;
}

function sidebar(active) {
  const status = state.status || {};
  const online = Boolean(status.online);
  const localURL = status.localURL || '';
  const tunnel = status.tunnel || {};
  return `
  <aside class="shell-sidebar hidden lg:flex flex-col gap-6 px-5 py-6 border-r" style="border-color:var(--border);background:rgba(0,0,0,.12)">
    <div class="flex items-center gap-3 px-1">
      <div class="w-10 h-10 rounded-2xl flex items-center justify-center" style="background:var(--accent-soft);color:var(--accent)">
        ${icon('server', 'w-5 h-5')}
      </div>
      <div class="min-w-0">
        <div class="text-[1.05rem] font-bold tracking-tight">PitHub</div>
        <div class="text-[0.62rem] muted truncate">家庭私有微型服务器</div>
      </div>
    </div>

    <nav class="flex flex-col gap-1">
      ${navItems().map((item) => navLink(item, active)).join('')}
    </nav>

    <div class="mt-auto space-y-3">
      <div class="glass-soft p-3">
        <div class="flex items-center gap-2 mb-2">
          <span class="dot ${online ? 'dot-online' : 'dot-offline'}"></span>
          <span class="text-[0.72rem] font-semibold">${online ? '服务在线' : '服务离线'}</span>
          <span class="badge ml-auto">${escapeHtml(roleLabel(state.auth && state.auth.role))}</span>
        </div>
        <div class="mono text-[0.65rem] truncate" style="color:var(--muted)">${escapeHtml(localURL || '尚未启动')}</div>
        ${tunnel.active ? `<div class="mono text-[0.62rem] truncate mt-1" style="color:var(--success)">${escapeHtml(tunnel.publicURL || '')}</div>` : ''}
        <div class="flex items-center gap-2 mt-3">
          <button class="btn btn-ghost btn-sm flex-1" data-theme-toggle>${themeIcon()}<span>外观</span></button>
          <button class="btn btn-ghost btn-sm btn-icon" data-logout title="退出登录">${icon('logout', 'w-4 h-4')}</button>
        </div>
      </div>
      <div class="text-[0.6rem] muted-2 px-1">v1.0.0 · 数据全部保存在本机</div>
    </div>
  </aside>`;
}

function mobileDrawer(active) {
  return `
  <div id="mobile-drawer" class="fixed inset-0 z-50 hidden lg:hidden">
    <div class="absolute inset-0 bg-black/55 backdrop-blur-sm" data-drawer-close></div>
    <div class="absolute left-0 top-0 bottom-0 w-[78vw] max-w-[300px] p-5 flex flex-col gap-5 border-r overflow-y-auto"
         style="background:var(--bg-2);border-color:var(--border)">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <div class="w-9 h-9 rounded-xl flex items-center justify-center" style="background:var(--accent-soft);color:var(--accent)">${icon('server', 'w-4 h-4')}</div>
          <span class="font-bold">PitHub</span>
        </div>
        <button class="btn btn-ghost btn-icon" data-drawer-close>${icon('close', 'w-4 h-4')}</button>
      </div>
      <nav class="flex flex-col gap-1">
        ${navItems().map((item) => navLink(item, active)).join('')}
      </nav>
      <div class="mt-auto flex items-center gap-2">
        <button class="btn btn-ghost btn-sm flex-1" data-theme-toggle>${themeIcon()}<span>切换外观</span></button>
        <button class="btn btn-ghost btn-sm btn-icon" data-logout>${icon('logout', 'w-4 h-4')}</button>
      </div>
    </div>
  </div>`;
}

function mobileNav(active) {
  const items = navItems().filter((item) => ['dashboard', 'file', 'photo', 'settings'].includes(item.key));
  return `
  <nav class="mobile-nav fixed bottom-0 left-0 right-0 z-40 grid grid-cols-4 lg:hidden">
    ${items.map((item) => `
      <a href="${item.href}" class="${active === item.key ? 'active' : ''}">
        ${icon(item.icon, 'w-[1.15rem] h-[1.15rem]')}
        <span>${escapeHtml(item.label)}</span>
      </a>`).join('')}
  </nav>`;
}

export function renderShell(active, title, contentHtml) {
  const status = state.status || {};
  const online = Boolean(status.online);
  const app = document.getElementById('app');
  app.innerHTML = `
    <div class="min-h-screen flex">
      ${sidebar(active)}
      <div class="flex-1 min-w-0 flex flex-col">
        <header class="sticky top-0 z-30 border-b" style="border-color:var(--border);background:rgba(5,7,12,.55);backdrop-filter:blur(22px) saturate(140%)">
          <div class="max-w-[1440px] mx-auto px-4 lg:px-8 h-16 flex items-center gap-3">
            <button class="btn btn-ghost btn-icon lg:hidden" data-drawer-open aria-label="菜单">${icon('menu', 'w-5 h-5')}</button>
            <div class="min-w-0">
              <div class="page-title truncate">${escapeHtml(title)}</div>
              <div class="text-[0.64rem] muted truncate hidden sm:block">PitHub · ${escapeHtml(status.serverName || '家庭私有云')}</div>
            </div>
            <div class="ml-auto flex items-center gap-2">
              <span class="badge ${online ? 'badge-success' : ''} hidden sm:inline-flex">
                <span class="dot ${online ? 'dot-online' : 'dot-offline'}"></span>
                ${online ? '在线' : '离线'}
              </span>
              <span class="badge hidden md:inline-flex">${escapeHtml(roleLabel(state.auth && state.auth.role))}</span>
              <button class="btn btn-ghost btn-icon" data-theme-toggle title="切换外观">${themeIcon()}</button>
              <button class="btn btn-ghost btn-icon" data-logout title="退出登录">${icon('logout', 'w-4 h-4')}</button>
            </div>
          </div>
        </header>
        <main class="flex-1 w-full max-w-[1440px] mx-auto px-4 lg:px-8 py-5 lg:py-7 pb-28 lg:pb-10">
          ${contentHtml}
        </main>
      </div>
    </div>
    ${mobileDrawer(active)}
    ${mobileNav(active)}
  `;

  const drawer = document.getElementById('mobile-drawer');
  app.querySelectorAll('[data-drawer-open]').forEach((button) => {
    button.addEventListener('click', () => drawer && drawer.classList.remove('hidden'));
  });
  app.querySelectorAll('[data-drawer-close]').forEach((button) => {
    button.addEventListener('click', () => drawer && drawer.classList.add('hidden'));
  });
  app.querySelectorAll('[data-theme-toggle]').forEach((button) => {
    button.addEventListener('click', () => {
      cycleTheme();
      app.querySelectorAll('[data-theme-toggle]').forEach((item) => {
        item.innerHTML = themeIcon();
      });
    });
  });
  app.querySelectorAll('[data-logout]').forEach((button) => {
    button.addEventListener('click', () => {
      window.dispatchEvent(new CustomEvent('pithub-logout'));
    });
  });
}


