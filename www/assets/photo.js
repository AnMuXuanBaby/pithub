//
// PhotoNode 相册面板：相册分组、年月筛选、网格、实况照片、视频预览。
//

import { api, state } from './api.js';
import {
  icon, escapeHtml, formatDate, formatDuration, toast, modal, emptyState
} from './ui.js';
// emptyState 已移到 ui.js，shell.js 负责页面外壳。
import { renderShell } from './shell.js';

const ph = {
  albums: [],
  assets: [],
  album: 'all',
  year: '',
  month: '',
  buckets: [],
  total: 0,
  offset: 0,
  loading: false,
  error: ''
};

function thumbURL(asset) {
  return api.photoThumbURL(asset.id, 'small');
}

export async function renderPhoto() {
  renderShell('photo', 'PhotoNode', layoutHTML());
  bindToolbar();
  await loadAll();
}

function layoutHTML() {
  return `
    <div class="grid lg:grid-cols-[228px_minmax(0,1fr)] gap-4 items-start">
      <aside class="glass p-3 lg:sticky lg:top-[84px]">
        <div class="flex items-center gap-2 px-1 mb-2">
          <div class="section-title">相册</div>
          <span class="badge ml-auto" id="ph-album-count">—</span>
        </div>
        <div id="ph-albums" class="flex lg:flex-col gap-1 overflow-x-auto pb-1 lg:pb-0"></div>
        <div class="divider my-3"></div>
        <div class="px-2 text-[0.66rem] leading-relaxed" style="color:var(--muted-2)">
          照片只读，不会上传到第三方。原图通过本机导出后流式下载，首次访问大视频可能需要等待。
        </div>
      </aside>
      <section class="min-w-0">
        <div class="glass overflow-hidden">
          <div class="p-4 border-b flex flex-wrap items-center gap-2" style="border-color:var(--border)">
            <div class="text-[0.82rem] font-semibold" id="ph-title">全部照片</div>
            <div class="badge" id="ph-count">—</div>
            <div class="ml-auto flex items-center gap-2 flex-wrap">
              <select class="field !h-9 !w-auto !text-[0.72rem]" id="ph-year"><option value="">全部年份</option></select>
              <select class="field !h-9 !w-auto !text-[0.72rem]" id="ph-month"><option value="">全部月份</option></select>
              <button class="btn btn-ghost btn-sm btn-icon" id="ph-refresh" title="刷新">${icon('refresh', 'w-3.5 h-3.5')}</button>
            </div>
          </div>
          <div class="p-3" id="ph-body">
            <div class="p-8 text-center text-[0.75rem] muted">正在读取相册…</div>
          </div>
        </div>
      </section>
    </div>`;
}

async function loadAll() {
  try {
    const [status, albumsData] = await Promise.all([api.photoStatus(), api.photoAlbums()]);
    if (!status.authorized) {
      ph.error = '尚未获得相册权限。请打开 PitHub App 授权相册访问。';
      ph.albums = [];
      ph.assets = [];
      updateAll();
      return;
    }
    ph.albums = albumsData.albums || [];
    if (!ph.albums.some((album) => album.id === ph.album)) {
      ph.album = ph.albums[0]?.id || 'all';
    }
    await loadTimeline();
    await loadAssets(true);
  } catch (error) {
    ph.error = error.message || '无法读取相册';
    ph.assets = [];
    updateAll();
  }
}

async function loadTimeline() {
  try {
    const data = await api.photoTimeline(ph.album);
    ph.buckets = data.buckets || [];
  } catch {
    ph.buckets = [];
  }
  updateFilters();
}

async function loadAssets(reset) {
  ph.loading = true;
  if (reset) {
    ph.assets = [];
    ph.offset = 0;
  }
  updateBody();
  try {
    const data = await api.photoAssets(
      ph.album,
      reset ? 0 : ph.offset,
      120,
      ph.year ? Number(ph.year) : undefined,
      ph.month ? Number(ph.month) : undefined
    );
    ph.total = data.total || 0;
    ph.assets = reset ? (data.items || []) : ph.assets.concat(data.items || []);
    ph.offset = ph.assets.length;
    ph.error = '';
  } catch (error) {
    ph.error = error.message || '加载相片失败';
  }
  ph.loading = false;
  updateBody();
  updateHeader();
}

async function switchAlbum(albumID) {
  ph.album = albumID;
  ph.year = '';
  ph.month = '';
  await loadTimeline();
  await loadAssets(true);
  updateAlbums();
  updateHeader();
}

function updateAll() {
  updateAlbums();
  updateFilters();
  updateHeader();
  updateBody();
}

function updateAlbums() {
  const container = document.getElementById('ph-albums');
  if (!container) return;
  const count = document.getElementById('ph-album-count');
  if (count) count.textContent = String(ph.albums.length);
  container.innerHTML = ph.albums.map((album) => {
    const active = album.id === ph.album;
    return `
      <button class="nav-link !py-2 ${active ? 'active' : ''}" data-album="${escapeHtml(album.id)}">
        <div class="w-8 h-8 rounded-lg overflow-hidden flex-none" style="background:var(--panel-strong)">
          ${album.coverAssetID
            ? `<img src="${api.photoThumbURL(album.coverAssetID, 'small')}" class="w-full h-full object-cover" loading="lazy" alt="">`
            : `<div class="w-full h-full flex items-center justify-center" style="color:var(--muted)">${icon('photo', 'w-4 h-4')}</div>`}
        </div>
        <div class="flex-1 min-w-0 text-left">
          <div class="text-[0.74rem] truncate">${escapeHtml(album.title)}</div>
          <div class="text-[0.58rem] muted-2">${album.count} 项</div>
        </div>
      </button>`;
  }).join('');

  container.querySelectorAll('[data-album]').forEach((button) => {
    button.addEventListener('click', () => switchAlbum(button.dataset.album));
  });
}

function updateFilters() {
  const yearSelect = document.getElementById('ph-year');
  const monthSelect = document.getElementById('ph-month');
  if (!yearSelect || !monthSelect) return;

  const years = Array.from(new Set(ph.buckets.map((bucket) => bucket.year))).sort((a, b) => b - a);
  yearSelect.innerHTML = `<option value="">全部年份</option>` +
    years.map((year) => `<option value="${year}" ${String(year) === ph.year ? 'selected' : ''}>${year} 年</option>`).join('');

  const months = ph.year
    ? ph.buckets.filter((bucket) => String(bucket.year) === ph.year).map((bucket) => bucket.month).sort((a, b) => b - a)
    : Array.from(new Set(ph.buckets.map((bucket) => bucket.month))).sort((a, b) => a - b);

  monthSelect.innerHTML = `<option value="">全部月份</option>` +
    months.map((month) => `<option value="${month}" ${String(month) === ph.month ? 'selected' : ''}>${month} 月</option>`).join('');
  monthSelect.disabled = false;

  yearSelect.onchange = () => {
    ph.year = yearSelect.value;
    ph.month = '';
    updateFilters();
    loadAssets(true);
  };
  monthSelect.onchange = () => {
    ph.month = monthSelect.value;
    loadAssets(true);
  };
}

function updateHeader() {
  const title = document.getElementById('ph-title');
  const count = document.getElementById('ph-count');
  if (title) {
    const album = ph.albums.find((item) => item.id === ph.album);
    title.textContent = album ? album.title : '全部照片';
  }
  if (count) count.textContent = `${ph.assets.length} / ${ph.total || ph.assets.length}`;
}

function updateBody() {
  const body = document.getElementById('ph-body');
  if (!body) return;
  if (ph.error) {
    body.innerHTML = emptyState(ph.error, '请在 App 内检查相册权限');
    return;
  }
  if (ph.loading && !ph.assets.length) {
    body.innerHTML = `<div class="p-8 text-center text-[0.75rem] muted">正在加载照片…</div>`;
    return;
  }
  if (!ph.assets.length) {
    body.innerHTML = emptyState('这个时间范围内没有照片', '换一个相册或年份试试');
    return;
  }
  body.innerHTML = `
    <div class="photo-grid" id="ph-grid">
      ${ph.assets.map((asset) => `
        <div class="photo-cell" data-photo="${escapeHtml(asset.id)}">
          <img src="${thumbURL(asset)}" loading="lazy" alt="${escapeHtml(asset.filename)}">
          ${asset.isLivePhoto ? '<span class="badge badge-accent photo-badge">LIVE</span>' : ''}
          ${asset.mediaType === 'video' ? `<span class="badge photo-duration">${formatDuration(asset.duration)}</span>` : ''}
        </div>`).join('')}
    </div>
    ${ph.assets.length < ph.total ? `<div class="p-4 text-center"><button class="btn btn-ghost btn-sm" id="ph-more">加载更多</button></div>` : ''}`;

  body.querySelectorAll('[data-photo]').forEach((cell) => {
    cell.addEventListener('click', () => {
      const asset = ph.assets.find((item) => item.id === cell.dataset.photo);
      if (asset) openPhoto(asset);
    });
  });
  body.querySelector('#ph-more')?.addEventListener('click', () => loadAssets(false));
}

function bindToolbar() {
  document.getElementById('ph-refresh')?.addEventListener('click', () => {
    loadAll();
    toast('正在刷新相册', 'success');
  });
}

function openPhoto(asset) {
  const isVideo = asset.mediaType === 'video';
  const imageURL = api.photoThumbURL(asset.id, 'large');
  const originalURL = api.photoOriginalURL(asset.id, false, false);
  const inlineVideoURL = api.photoOriginalURL(asset.id, false, true);
  const liveVideoURL = api.photoOriginalURL(asset.id, 'video');

  const content = `
    <div class="space-y-3">
      <div class="rounded-2xl overflow-hidden bg-black flex items-center justify-center" style="min-height:220px">
        ${isVideo
          ? `<video src="${inlineVideoURL}" controls autoplay playsinline class="max-h-[70vh] w-full"></video>`
          : `<img id="ph-preview-img" src="${imageURL}" alt="" class="max-h-[70vh] w-full object-contain">`}
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <div class="min-w-0 flex-1">
          <div class="text-[0.8rem] font-semibold truncate">${escapeHtml(asset.filename)}</div>
          <div class="text-[0.64rem] muted mt-0.5">${formatDate(asset.createdAt)} · ${asset.pixelWidth}×${asset.pixelHeight}${asset.isLivePhoto ? ' · 实况照片' : ''}</div>
        </div>
        <button class="btn btn-ghost btn-sm" data-download-original>${icon('download', 'w-3.5 h-3.5')}原图</button>
        ${asset.isLivePhoto && !isVideo ? `<button class="btn btn-ghost btn-sm" data-download-live>${icon('video', 'w-3.5 h-3.5')}实况视频</button>` : ''}
        <button class="btn btn-primary btn-sm" data-close>关闭</button>
      </div>
      ${asset.isLivePhoto && !isVideo ? `<div class="text-[0.64rem] muted-2">实况照片的原图与配对视频会分别下载。</div>` : ''}
    </div>`;

  const dialog = modal({
    title: asset.filename,
    content,
    wide: true,
    plain: !isVideo
  });

  dialog.root.querySelector('[data-close]').addEventListener('click', dialog.close);
  dialog.root.querySelector('[data-download-original]')?.addEventListener('click', () => {
    const anchor = document.createElement('a');
    anchor.href = originalURL;
    anchor.download = asset.filename;
    anchor.click();
  });
  dialog.root.querySelector('[data-download-live]')?.addEventListener('click', () => {
    const anchor = document.createElement('a');
    anchor.href = liveVideoURL;
    anchor.download = asset.filename.replace(/\.[^.]+$/, '') + '-live.mov';
    anchor.click();
  });
}


