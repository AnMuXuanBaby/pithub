//
// 设置面板：全局 / 隧道 / 各插件配置 / 缓存。与 App 本机设置同一份数据。
//

import { api, state } from './api.js';
import {
  icon, escapeHtml, toast, modal, confirmDialog, copyText, formatBytes
} from './ui.js';
import { renderShell } from './shell.js';

const view = { settings: null, guide: null, albums: [], error: '' };

function isAdmin() { return state.auth && state.auth.role === 'admin'; }

export async function renderSettings() {
  if (!isAdmin()) {
    renderShell('settings', '设置', `
      <div class="glass p-8 text-center">
        <div class="text-[0.95rem] font-semibold mb-2">仅管理员可访问</div>
        <div class="text-[0.72rem] muted">访客与普通用户不能查看端口、密码、隧道令牌等配置。</div>
      </div>`);
    return;
  }
  renderShell('settings', '设置', `<div class="glass p-8 text-center text-[0.78rem] muted">正在读取设置…</div>`);
  try {
    const data = await api.settings();
    view.settings = data.settings;
    view.error = '';
  } catch (error) {
    view.settings = null;
    view.error = error.message || '无法读取设置';
  }
  try {
    view.guide = await api.tunnelGuide();
  } catch {
    view.guide = null;
  }
  if (view.settings && view.settings.pluginEnabled?.photo !== false) {
    try {
      const albumsData = await api.photoAlbums();
      view.albums = albumsData.albums || [];
    } catch {
      view.albums = [];
    }
  }
  render();
}

function render() {
  if (!view.settings) {
    renderShell('settings', '设置', `
      <div class="glass p-8 text-center">
        <div class="text-[0.9rem] font-semibold mb-2">无法读取设置</div>
        <div class="text-[0.72rem] muted">${escapeHtml(view.error)}</div>
      </div>`);
    return;
  }

  const s = view.settings;
  const disabled = isAdmin() ? '' : 'disabled';
  const guide = view.guide || {};
  const albumIDs = s.photoNode.allowedAlbumIDs || [];
  const allowAll = albumIDs.length === 0;

  renderShell('settings', '设置', `
    <div class="space-y-4">
      ${isAdmin() ? '' : `<div class="glass p-4 text-[0.72rem] flex items-center gap-2" style="color:var(--warning)">
        ${icon('lock', 'w-4 h-4')}当前是只读角色，设置只能查看不能保存。
      </div>`}

      <form id="settings-form" class="space-y-4">
        <section class="glass p-5">
          <div class="flex items-center gap-2 mb-4">
            <div class="icon-tile">${icon('server', 'w-5 h-5')}</div>
            <div>
              <div class="font-semibold text-[0.92rem]">服务</div>
              <div class="text-[0.65rem] muted">端口修改后会自动重启 HTTP 监听</div>
            </div>
            <span class="badge badge-success ml-auto">${escapeHtml(s.isDefaultPassword ? '默认密码' : '已自定义密码')}</span>
          </div>
          <div class="grid sm:grid-cols-2 gap-3">
            <div>
              <label class="field-label">端口</label>
              <input class="field" type="number" min="1" max="65535" id="set-port" value="${escapeHtml(s.port)}" ${disabled}>
            </div>
            <div>
              <label class="field-label">Bonjour 名称</label>
              <input class="field" id="set-bonjour" value="${escapeHtml(s.bonjourName)}" ${disabled}>
            </div>
            <div>
              <label class="field-label">会话超时（分钟）</label>
              <input class="field" type="number" min="5" max="43200" id="set-session" value="${escapeHtml(s.sessionTimeoutMinutes)}" ${disabled}>
            </div>
            <div>
              <label class="field-label">日志保留条数</label>
              <input class="field" type="number" min="100" max="20000" step="100" id="set-log-retention" value="${escapeHtml(s.logRetention)}" ${disabled}>
            </div>
          </div>
          <label class="flex items-center gap-2 text-[0.74rem] muted mt-4">
            <input type="checkbox" id="set-guest" class="w-4 h-4 accent-[var(--accent)]" ${s.guestEnabled ? 'checked' : ''} ${disabled}>
            允许访客只读登录（不需要密码）
          </label>
        </section>

        <section class="glass p-5">
          <div class="flex items-center gap-2 mb-4">
            <div class="icon-tile">${icon('lock', 'w-5 h-5')}</div>
            <div>
              <div class="font-semibold text-[0.92rem]">访问密码</div>
              <div class="text-[0.65rem] muted">网页、API、WebDAV 共用；WebDAV 用户名 admin 表示管理员</div>
            </div>
            ${s.isDefaultPassword ? '<span class="badge badge-warning ml-auto">建议修改</span>' : ''}
          </div>
          <div class="grid sm:grid-cols-2 gap-3">
            <div>
              <label class="field-label">新的访问密码（普通用户）</label>
              <input class="field" type="password" id="set-access-password" placeholder="留空则不修改" ${disabled}>
            </div>
            <div>
              <label class="field-label">新的管理员密码</label>
              <input class="field" type="password" id="set-admin-password" placeholder="留空则不修改" ${disabled}>
            </div>
          </div>
          <div class="field-hint">默认密码为 pithub。修改后已有会话仍然有效，可手动退出再登录验证。</div>
        </section>

        <section class="glass p-5">
          <div class="flex items-center gap-2 mb-4">
            <div class="icon-tile">${icon('globe', 'w-5 h-5')}</div>
            <div>
              <div class="font-semibold text-[0.92rem]">外网隧道</div>
              <div class="text-[0.65rem] muted">全局开关，独立于插件；只转发流量，不存储数据</div>
            </div>
            <span class="badge ${state.status?.tunnel?.active ? 'badge-success' : ''} ml-auto">${escapeHtml(state.status?.tunnel?.message || '')}</span>
          </div>
          <div class="grid sm:grid-cols-2 gap-3">
            <div>
              <label class="field-label">隧道方案</label>
              <select class="field" id="set-tunnel-provider" ${disabled}>
                ${providerOption('none', '仅局域网', s.tunnelProvider)}
                ${providerOption('cloudflare', 'Cloudflare Tunnel（外部连接器）', s.tunnelProvider)}
                ${providerOption('relay', 'PitHub Relay（App 内一键）', s.tunnelProvider)}
                ${providerOption('frp', 'frp（外部客户端）', s.tunnelProvider)}
              </select>
            </div>
            <div>
              <label class="field-label">外网限速（KB/s，0 = 不限速）</label>
              <input class="field" type="number" min="0" max="102400" id="set-wan-rate" value="${escapeHtml(s.wanRateLimitKBps)}" ${disabled}>
            </div>
            <div>
              <label class="field-label">Cloudflare / frp 公网地址</label>
              <input class="field" id="set-tunnel-url" value="${escapeHtml(s.tunnelPublicURL)}" placeholder="https://xxx.trycloudflare.com" ${disabled}>
            </div>
            <div>
              <label class="field-label">Relay 地址</label>
              <input class="field" id="set-relay-url" value="${escapeHtml(s.relayURL)}" placeholder="https://relay.example.com" ${disabled}>
            </div>
            <div>
              <label class="field-label">Relay Token</label>
              <input class="field" type="password" id="set-relay-token" placeholder="${s.relayTokenConfigured ? '已配置，留空保持不变' : '未配置'}" ${disabled}>
            </div>
            <div class="flex items-end">
              <label class="flex items-center gap-2 text-[0.72rem] muted">
                <input type="checkbox" id="set-clear-relay-token" class="w-4 h-4 accent-[var(--accent)]" ${disabled}>
                清除已保存的 Relay Token
              </label>
            </div>
          </div>
          <label class="flex items-center gap-2 text-[0.74rem] muted mt-4">
            <input type="checkbox" id="set-tunnel-enabled" class="w-4 h-4 accent-[var(--accent)]" ${s.tunnelEnabled ? 'checked' : ''} ${disabled}>
            开启外网隧道
          </label>
          <div class="field-hint">
            iOS 沙盒不允许 App 启动 cloudflared/frpc，需要外部连接器；Relay 模式由 App 主动连出，无需公网 IP。
          </div>

          ${guide.cloudflareCommand ? `
          <div class="mt-4 space-y-2">
            <div class="flex items-center gap-2">
              <div class="section-title">Cloudflare 命令</div>
              <button type="button" class="btn btn-ghost btn-sm ml-auto" data-copy-guide="cloudflare">${icon('copy', 'w-3.5 h-3.5')}复制</button>
            </div>
            <pre class="code-block" id="guide-cloudflare">${escapeHtml(guide.cloudflareCommand)}</pre>
          </div>
          <div class="mt-4 space-y-2">
            <div class="flex items-center gap-2">
              <div class="section-title">frp 配置模板</div>
              <button type="button" class="btn btn-ghost btn-sm ml-auto" data-copy-guide="frp">${icon('copy', 'w-3.5 h-3.5')}复制</button>
            </div>
            <pre class="code-block" id="guide-frp">${escapeHtml(guide.frpConfig || '')}</pre>
          </div>
          <div class="mt-3 text-[0.66rem] leading-relaxed" style="color:var(--muted-2)">${escapeHtml(guide.iosLimit || '')}</div>
          ` : ''}
        </section>

        <section class="glass p-5">
          <div class="flex items-center gap-2 mb-4">
            <div class="icon-tile">${icon('moon', 'w-5 h-5')}</div>
            <div>
              <div class="font-semibold text-[0.92rem]">后台与通知</div>
              <div class="text-[0.65rem] muted">iOS 后台限制无法绕过，请插电常驻</div>
            </div>
          </div>
          <div class="grid sm:grid-cols-2 gap-3">
            <div>
              <label class="field-label">锁屏策略</label>
              <select class="field" id="set-background" ${disabled}>
                <option value="pauseOnLock" ${s.backgroundPolicy === 'pauseOnLock' ? 'selected' : ''}>锁屏暂停服务</option>
                <option value="keepAlive" ${s.backgroundPolicy === 'keepAlive' ? 'selected' : ''}>锁屏尽量保活</option>
              </select>
            </div>
            <div class="flex flex-col justify-end gap-2">
              <label class="flex items-center gap-2 text-[0.74rem] muted">
                <input type="checkbox" id="set-prevent-lock" class="w-4 h-4 accent-[var(--accent)]" ${s.preventAutoLock ? 'checked' : ''} ${disabled}>
                屏幕常亮
              </label>
              <label class="flex items-center gap-2 text-[0.74rem] muted">
                <input type="checkbox" id="set-notifications" class="w-4 h-4 accent-[var(--accent)]" ${s.notificationsEnabled ? 'checked' : ''} ${disabled}>
                本地通知
              </label>
              <label class="flex items-center gap-2 text-[0.74rem] muted">
                <input type="checkbox" id="set-biometric" class="w-4 h-4 accent-[var(--accent)]" ${s.biometricForSensitive ? 'checked' : ''} ${disabled}>
                敏感操作需要 Face ID（预留）
              </label>
            </div>
          </div>
        </section>

        <section class="glass p-5">
          <div class="flex items-center gap-2 mb-4">
            <div class="icon-tile">${icon('folder', 'w-5 h-5')}</div>
            <div>
              <div class="font-semibold text-[0.92rem]">FilePit</div>
              <div class="text-[0.65rem] muted">上传、分享、ZIP 与相册挂载</div>
            </div>
          </div>
          <div class="grid sm:grid-cols-3 gap-3">
            <div>
              <label class="field-label">上传上限（MB）</label>
              <input class="field" type="number" min="1" max="65536" id="set-upload-max" value="${escapeHtml(s.filePit.maxUploadMB)}" ${disabled}>
            </div>
            <div>
              <label class="field-label">分享默认有效期（分钟）</label>
              <input class="field" type="number" min="1" max="10080" id="set-share-expiry" value="${escapeHtml(s.filePit.shareExpiryMinutes)}" ${disabled}>
            </div>
            <div>
              <label class="field-label">分片大小（MB）</label>
              <input class="field" type="number" min="1" max="64" id="set-chunk" value="${escapeHtml(s.filePit.chunkMB)}" ${disabled}>
            </div>
          </div>
          <div class="mt-3">
            <label class="field-label">禁止上传的扩展名（逗号分隔）</label>
            <input class="field" id="set-blocked" value="${escapeHtml((s.filePit.blockedExtensions || []).join(', '))}" ${disabled}>
          </div>
          <div class="flex flex-wrap gap-4 mt-4">
            <label class="flex items-center gap-2 text-[0.74rem] muted">
              <input type="checkbox" id="set-zip" class="w-4 h-4 accent-[var(--accent)]" ${s.filePit.allowZipDownload ? 'checked' : ''} ${disabled}>
              允许 ZIP 打包下载
            </label>
            <label class="flex items-center gap-2 text-[0.74rem] muted">
              <input type="checkbox" id="set-photo-mount" class="w-4 h-4 accent-[var(--accent)]" ${s.filePit.allowPhotoMount ? 'checked' : ''} ${disabled}>
              把相册挂载到 /photos
            </label>
          </div>
        </section>

        <section class="glass p-5">
          <div class="flex items-center gap-2 mb-4">
            <div class="icon-tile">${icon('photo', 'w-5 h-5')}</div>
            <div>
              <div class="font-semibold text-[0.92rem]">PhotoNode</div>
              <div class="text-[0.65rem] muted">相册白名单与缩略图质量</div>
            </div>
          </div>
          <div class="grid sm:grid-cols-2 gap-3">
            <div>
              <label class="field-label">缩略图质量（%）</label>
              <input class="field" type="number" min="30" max="100" id="set-thumb-quality" value="${escapeHtml(s.photoNode.thumbnailQuality)}" ${disabled}>
            </div>
            <div class="flex flex-col justify-end gap-2">
              <label class="flex items-center gap-2 text-[0.74rem] muted">
                <input type="checkbox" id="set-photo-videos" class="w-4 h-4 accent-[var(--accent)]" ${s.photoNode.includeVideos ? 'checked' : ''} ${disabled}>
                共享视频
              </label>
              <label class="flex items-center gap-2 text-[0.74rem] muted">
                <input type="checkbox" id="set-photo-hidden" class="w-4 h-4 accent-[var(--accent)]" ${s.photoNode.includeHiddenAssets ? 'checked' : ''} ${disabled}>
                包含隐藏照片
              </label>
            </div>
          </div>
          <div class="mt-4">
            <label class="flex items-center gap-2 text-[0.74rem] font-semibold">
              <input type="checkbox" id="set-photo-all" class="w-4 h-4 accent-[var(--accent)]" ${allowAll ? 'checked' : ''} ${disabled}>
              共享全部相册
            </label>
            <div class="field-hint">关闭后只共享下面勾选的相册。FilePit 的 /photos 也遵守同一白名单。</div>
            <div class="grid sm:grid-cols-2 gap-1.5 mt-2 max-h-56 overflow-y-auto" id="photo-album-list">
              ${view.albums.length
                ? view.albums.filter((album) => album.id !== 'all').map((album) => `
                    <label class="flex items-center gap-2 text-[0.72rem] px-2 py-1.5 rounded-lg" style="background:var(--panel)">
                      <input type="checkbox" data-album-id="${escapeHtml(album.id)}" class="w-4 h-4 accent-[var(--accent)]"
                        ${!allowAll && albumIDs.includes(album.id) ? 'checked' : ''} ${allowAll || !isAdmin() ? 'disabled' : ''}>
                      <span class="truncate flex-1">${escapeHtml(album.title)}</span>
                      <span class="muted-2 text-[0.6rem]">${album.count}</span>
                    </label>`).join('')
                : '<div class="text-[0.68rem] muted p-2">未读取到相册（可能未授权或插件已禁用）</div>'}
            </div>
          </div>
        </section>

        <section class="glass p-5">
          <div class="flex items-center gap-2 mb-4">
            <div class="icon-tile">${icon('clipboard', 'w-5 h-5')}</div>
            <div>
              <div class="font-semibold text-[0.92rem]">ClipHub</div>
              <div class="text-[0.65rem] muted">保留上限与自动淘汰</div>
            </div>
          </div>
          <div class="grid sm:grid-cols-3 gap-3">
            <div>
              <label class="field-label">最大记录数</label>
              <input class="field" type="number" min="10" max="5000" id="set-clip-max" value="${escapeHtml(s.clipHub.maxRecords)}" ${disabled}>
            </div>
            <div>
              <label class="field-label">单条上限（MB）</label>
              <input class="field" type="number" min="1" max="64" id="set-clip-item" value="${escapeHtml(s.clipHub.maxItemMB)}" ${disabled}>
            </div>
            <div>
              <label class="field-label">保留天数</label>
              <input class="field" type="number" min="1" max="3650" id="set-clip-retention" value="${escapeHtml(s.clipHub.retentionDays)}" ${disabled}>
            </div>
          </div>
        </section>

        <section class="glass p-5">
          <div class="flex items-center gap-2 mb-4">
            <div class="icon-tile">${icon('bolt', 'w-5 h-5')}</div>
            <div>
              <div class="font-semibold text-[0.92rem]">DashLink</div>
              <div class="text-[0.65rem] muted">调用冷却与执行记录上限</div>
            </div>
          </div>
          <div class="grid sm:grid-cols-2 gap-3">
            <div>
              <label class="field-label">默认冷却（秒）</label>
              <input class="field" type="number" min="0" max="3600" id="set-dash-cooldown" value="${escapeHtml(s.dashLink.cooldownSeconds)}" ${disabled}>
            </div>
            <div>
              <label class="field-label">执行记录上限</label>
              <input class="field" type="number" min="10" max="5000" id="set-dash-runs" value="${escapeHtml(s.dashLink.maxRuns)}" ${disabled}>
            </div>
          </div>
        </section>

        <section class="glass p-5">
          <div class="flex items-center gap-2 mb-4">
            <div class="icon-tile">${icon('archive', 'w-5 h-5')}</div>
            <div>
              <div class="font-semibold text-[0.92rem]">缓存</div>
              <div class="text-[0.65rem] muted">所有插件共享的 LRU 磁盘缓存</div>
            </div>
            <button type="button" class="btn btn-danger btn-sm ml-auto" id="clear-cache" ${disabled}>${icon('trash', 'w-3.5 h-3.5')}清空缓存</button>
          </div>
          <div class="grid sm:grid-cols-3 gap-3">
            <div>
              <label class="field-label">缓存上限（MB）</label>
              <input class="field" type="number" min="64" max="4096" id="set-cache-limit" value="${escapeHtml(s.cacheLimitMB)}" ${disabled}>
            </div>
            <div class="text-[0.7rem] muted">
              <div class="field-label">共享缓存</div>
              <div class="mono" id="cache-shared">—</div>
            </div>
            <div class="text-[0.7rem] muted">
              <div class="field-label">缩略图缓存</div>
              <div class="mono" id="cache-thumbs">—</div>
            </div>
          </div>
        </section>

        ${isAdmin() ? `<div class="sticky bottom-20 lg:bottom-6 flex justify-end">
          <button class="btn btn-primary btn-lg" type="submit">${icon('check', 'w-4 h-4')}保存全部设置</button>
        </div>` : ''}
      </form>

      <section class="glass p-5">
        <div class="section-title mb-2">关于</div>
        <div class="grid sm:grid-cols-3 gap-3 text-[0.7rem]">
          <div><span class="muted">版本：</span><span class="mono">1.1.0</span></div>
          <div><span class="muted">WebDAV：</span><span class="mono">${escapeHtml((state.status?.shareBaseURL || '') + '/webdav')}</span></div>
          <div><span class="muted">默认密码：</span><span class="mono">pithub</span></div>
        </div>
        <div class="field-hint">所有数据保存在本机 iPhone；隧道只转发流量，不存储数据。</div>
    <div class="field-hint">如果修改了端口，保存后当前页面可能断开，请用新端口重新访问。</div>
      </section>
    </div>
  `);

  bind();
}

function providerOption(value, label, current) {
  return `<option value="${value}" ${current === value ? 'selected' : ''}>${escapeHtml(label)}</option>`;
}

function bind() {
  const app = document.getElementById('app');
  const form = document.getElementById('settings-form');

  app.querySelectorAll('[data-copy-guide]').forEach((button) => {
    button.addEventListener('click', () => {
      const source = button.dataset.copyGuide === 'cloudflare' ? view.guide?.cloudflareCommand : view.guide?.frpConfig;
      copyText(source || '');
    });
  });

  document.getElementById('clear-cache')?.addEventListener('click', async () => {
    const ok = await confirmDialog('清空缓存？', '缩略图、ZIP 与预览缓存都会被删除，不会影响原文件。', '清空');
    if (!ok) return;
    try {
      await api.clearCache();
      toast('缓存已清空', 'success');
      loadCacheStats();
    } catch (error) { toast(error.message, 'error'); }
  });

  const allowAll = document.getElementById('set-photo-all');
  allowAll?.addEventListener('change', () => {
    document.querySelectorAll('[data-album-id]').forEach((checkbox) => {
      checkbox.disabled = allowAll.checked || !isAdmin();
      if (allowAll.checked) checkbox.checked = false;
    });
  });

  form?.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (!isAdmin()) return;
    try {
      await api.saveSettings(collectPayload());
      toast('设置已保存', 'success');
      const data = await api.settings();
      view.settings = data.settings;
      setTimeout(() => { if (state.route === 'settings') renderSettings(); }, 1200);
    } catch (error) {
      toast(error.message, 'error');
    }
  });

  loadCacheStats();
}

async function loadCacheStats() {
  try {
    const stats = await api.cacheStats();
    const shared = document.getElementById('cache-shared');
    const thumbs = document.getElementById('cache-thumbs');
    if (shared) shared.textContent = formatBytes(stats.sharedBytes);
    if (thumbs) thumbs.textContent = formatBytes(stats.thumbnailBytes);
  } catch {}
}

function numberValue(id) {
  const element = document.getElementById(id);
  return element ? Number(element.value) : 0;
}

function stringValue(id) {
  const element = document.getElementById(id);
  return element ? element.value.trim() : '';
}

function checked(id) {
  return Boolean(document.getElementById(id)?.checked);
}

function collectPayload() {
  const allowAll = checked('set-photo-all');
  const albumIDs = Array.from(document.querySelectorAll('[data-album-id]:checked'))
    .map((checkbox) => checkbox.dataset.albumId);

  if (!allowAll && albumIDs.length === 0) {
    throw new Error('请至少选择一个相册，或开启“共享全部相册”');
  }

  const payload = {
    port: numberValue('set-port'),
    bonjourName: stringValue('set-bonjour'),
    sessionTimeoutMinutes: numberValue('set-session'),
    logRetention: numberValue('set-log-retention'),
    guestEnabled: checked('set-guest'),
    tunnelEnabled: checked('set-tunnel-enabled'),
    tunnelProvider: document.getElementById('set-tunnel-provider').value,
    wanRateLimitKBps: numberValue('set-wan-rate'),
    tunnelPublicURL: stringValue('set-tunnel-url'),
    relayURL: stringValue('set-relay-url'),
    backgroundPolicy: document.getElementById('set-background').value,
    preventAutoLock: checked('set-prevent-lock'),
    notificationsEnabled: checked('set-notifications'),
    biometricForSensitive: checked('set-biometric'),
    cacheLimitMB: numberValue('set-cache-limit'),
    filePit: {
      maxUploadMB: numberValue('set-upload-max'),
      shareExpiryMinutes: numberValue('set-share-expiry'),
      chunkMB: numberValue('set-chunk'),
      blockedExtensions: stringValue('set-blocked').split(',').map((value) => value.trim().replace(/^\./, '')).filter(Boolean),
      allowZipDownload: checked('set-zip'),
      allowPhotoMount: checked('set-photo-mount')
    },
    photoNode: {
      thumbnailQuality: numberValue('set-thumb-quality'),
      includeVideos: checked('set-photo-videos'),
      includeHiddenAssets: checked('set-photo-hidden'),
      allowedAlbumIDs: allowAll ? [] : albumIDs
    },
    clipHub: {
      maxRecords: numberValue('set-clip-max'),
      maxItemMB: numberValue('set-clip-item'),
      retentionDays: numberValue('set-clip-retention')
    },
    dashLink: {
      cooldownSeconds: numberValue('set-dash-cooldown'),
      maxRuns: numberValue('set-dash-runs')
    }
  };

  const accessPassword = stringValue('set-access-password');
  if (accessPassword) payload.newAccessPassword = accessPassword;
  const adminPassword = stringValue('set-admin-password');
  if (adminPassword) payload.newAdminPassword = adminPassword;

  const relayToken = stringValue('set-relay-token');
  if (relayToken) payload.relayToken = relayToken;
  else if (checked('set-clear-relay-token')) payload.relayToken = '';

  return payload;
}
