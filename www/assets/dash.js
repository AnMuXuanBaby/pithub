//
// DashLink 中控面板：自定义按钮、调用快捷指令、执行记录。
//

import { api, state } from './api.js';
import {
  icon, escapeHtml, formatShortDate, toast, modal, confirmDialog, copyText, emptyState
} from './ui.js';
import { renderShell } from './shell.js';

const dash = { buttons: [], runs: [], cooldown: 0, error: '' };

function isUser() { return state.auth && (state.auth.role === 'user' || state.auth.role === 'admin'); }

export async function renderDash() {
  if (!isUser()) {
    renderShell('dash', 'DashLink', `
      <div class="glass p-8 text-center">
        <div class="text-[0.95rem] font-semibold mb-2">需要用户或管理员权限</div>
        <div class="text-[0.72rem] muted">快捷指令按钮属于配置与执行能力，访客不可查看。</div>
      </div>`);
    return;
  }
  renderShell('dash', 'DashLink', layoutHTML());
  bindStatic();
  await load();
}

function layoutHTML() {
  return `
    <div class="space-y-4">
      <section class="glass p-5">
        <div class="flex flex-wrap items-center gap-2">
          <div class="icon-tile">${icon('bolt', 'w-5 h-5')}</div>
          <div>
            <div class="text-[0.98rem] font-semibold">快捷指令网关</div>
            <div class="text-[0.68rem] muted">按钮 → shortcuts://run-shortcut → 本机快捷指令</div>
          </div>
          <div class="ml-auto flex items-center gap-2">
            <button class="btn btn-ghost btn-sm" id="dash-refresh">${icon('refresh', 'w-3.5 h-3.5')}刷新</button>
            ${isUser() ? `<button class="btn btn-primary btn-sm" id="dash-add">${icon('plus', 'w-3.5 h-3.5')}新增按钮</button>` : ''}
          </div>
        </div>
        <div class="text-[0.66rem] mt-3 leading-relaxed" style="color:var(--muted-2)">
          iOS 没有公开 API 枚举快捷指令，需要手动填写快捷指令名称。系统不会把执行结果回传给 App，
          可在快捷指令末尾用「获取 URL 内容」把结果 POST 到运行时返回的 callbackURL。
        </div>
      </section>

      <section>
        <div class="flex items-center gap-2 mb-3">
          <div class="section-title">按钮面板</div>
          <span class="badge" id="dash-count">—</span>
        </div>
        <div id="dash-buttons" class="grid sm:grid-cols-2 xl:grid-cols-3 gap-3"></div>
      </section>

      <section class="glass overflow-hidden">
        <div class="p-4 border-b flex items-center gap-2" style="border-color:var(--border)">
          <div class="section-title">执行记录</div>
          <span class="badge ml-auto" id="dash-run-count">—</span>
          ${isUser() ? `<button class="btn btn-ghost btn-sm" id="dash-clear-runs">清空</button>` : ''}
        </div>
        <div class="p-3" id="dash-runs"></div>
      </section>
    </div>`;
}

function bindStatic() {
  document.getElementById('dash-refresh')?.addEventListener('click', () => load());
  document.getElementById('dash-add')?.addEventListener('click', () => openButtonEditor(null));
  document.getElementById('dash-clear-runs')?.addEventListener('click', async () => {
    const ok = await confirmDialog('清空执行记录？', '只删除记录，不会删除按钮或快捷指令。', '清空');
    if (!ok) return;
    try {
      await api.dashClear();
      toast('已清空执行记录', 'success');
      await load();
    } catch (error) { toast(error.message, 'error'); }
  });
}

async function load() {
  try {
    const [buttonsData, runsData] = await Promise.all([api.dashButtons(), api.dashRuns(30)]);
    dash.buttons = buttonsData.buttons || [];
    dash.cooldown = buttonsData.cooldownSeconds || 0;
    dash.runs = runsData.runs || [];
    dash.error = '';
  } catch (error) {
    dash.error = error.message || '无法读取 DashLink';
    dash.buttons = [];
    dash.runs = [];
  }
  renderButtons();
  renderRuns();
}

function renderButtons() {
  const container = document.getElementById('dash-buttons');
  const count = document.getElementById('dash-count');
  if (count) count.textContent = `${dash.buttons.length} 个`;
  if (!container) return;
  if (dash.error) { container.innerHTML = emptyState(dash.error, '请确认 DashLink 插件已启用'); return; }
  if (!dash.buttons.length) {
    container.innerHTML = `<div class="glass p-6">${emptyState('还没有快捷指令按钮', isUser() ? '点击右上角“新增按钮”开始配置' : '请在网页管理员账号下配置')}</div>`;
    return;
  }

  container.innerHTML = dash.buttons.map((button) => {
    const color = normalizeColor(button.color);
    const cooling = Number(button.cooldownRemaining || 0) > 0;
    return `
      <div class="plugin-card" style="border-color:${color}40">
        <button class="text-left flex flex-col gap-3" data-run="${escapeHtml(button.id)}">
          <div class="flex items-center gap-2">
            <div class="w-9 h-9 rounded-xl flex items-center justify-center flex-none" style="background:${color}22;color:${color}">
              ${icon('bolt', 'w-4 h-4')}
            </div>
            <div class="min-w-0">
              <div class="text-[0.86rem] font-semibold truncate">${escapeHtml(button.title)}</div>
              <div class="text-[0.62rem] muted truncate mono">${escapeHtml(button.shortcutName)}</div>
            </div>
            ${cooling ? `<span class="badge badge-warning ml-auto">${button.cooldownRemaining}s</span>` : `<span class="badge badge-success ml-auto">就绪</span>`}
          </div>
          <div class="text-[0.64rem] muted-2 line-clamp-2">${escapeHtml(button.inputTemplate || '直接运行快捷指令，可额外传入文本参数')}</div>
        </button>
        ${isUser() ? `<div class="flex items-center gap-1 mt-auto pt-1">
          <button class="btn btn-ghost btn-sm" data-edit="${escapeHtml(button.id)}">${icon('edit', 'w-3.5 h-3.5')}编辑</button>
          <button class="btn btn-ghost btn-sm btn-icon" data-delete="${escapeHtml(button.id)}">${icon('trash', 'w-3.5 h-3.5')}</button>
        </div>` : ''}
      </div>`;
  }).join('');

  container.querySelectorAll('[data-run]').forEach((element) => {
    element.addEventListener('click', () => {
      const button = dash.buttons.find((item) => item.id === element.dataset.run);
      if (button) openRun(button);
    });
  });
  container.querySelectorAll('[data-edit]').forEach((element) => {
    element.addEventListener('click', (event) => {
      event.stopPropagation();
      const button = dash.buttons.find((item) => item.id === element.dataset.edit);
      if (button) openButtonEditor(button);
    });
  });
  container.querySelectorAll('[data-delete]').forEach((element) => {
    element.addEventListener('click', async (event) => {
      event.stopPropagation();
      const button = dash.buttons.find((item) => item.id === element.dataset.delete);
      if (!button) return;
      const ok = await confirmDialog('删除按钮？', `将删除「${button.title}」，不会影响快捷指令本身。`, '删除');
      if (!ok) return;
      try {
        await api.dashDelete(button.id);
        toast('已删除', 'success');
        await load();
      } catch (error) { toast(error.message, 'error'); }
    });
  });
}

function openRun(button) {
  if (!isUser()) { toast('访客不能调用快捷指令', 'error'); return; }
  if (Number(button.cooldownRemaining || 0) > 0) {
    toast(`冷却中，请 ${button.cooldownRemaining} 秒后再试`, 'error');
    return;
  }
  const dialog = modal({
    title: `运行 · ${button.title}`,
    content: `
      <div class="text-[0.7rem] muted mb-3">快捷指令：<span class="mono">${escapeHtml(button.shortcutName)}</span></div>
      <label class="field-label">输入文本（可选）</label>
      <textarea id="dash-input" class="field" rows="3" placeholder="会作为 text 参数传给快捷指令"></textarea>
      <div class="field-hint">调用后会跳转到“快捷指令”App，执行结束后需要手动返回浏览器。</div>`,
    footer: `<button class="btn btn-ghost" data-cancel>取消</button><button class="btn btn-primary" data-run-now>${icon('play', 'w-3.5 h-3.5')}执行</button>`
  });
  dialog.root.querySelector('[data-cancel]').addEventListener('click', dialog.close);
  dialog.root.querySelector('[data-run-now]').addEventListener('click', async () => {
    const text = dialog.root.querySelector('#dash-input').value;
    dialog.close();
    try {
      const data = await api.dashRun(button.id, text);
      showRunResult(data);
      await load();
    } catch (error) { toast(error.message, 'error'); }
  });
}

function showRunResult(data) {
  const run = data.run || {};
  const callbackURL = data.callbackURL || run.callbackURL || '';
  const dialog = modal({
    title: '已请求调用快捷指令',
    content: `
      <div class="space-y-3">
        <div class="flex items-center gap-2">
          <span class="badge badge-success">LAUNCHED</span>
          <span class="text-[0.76rem] font-medium">${escapeHtml(run.buttonTitle || '')}</span>
        </div>
        <div class="text-[0.7rem] muted leading-relaxed">${escapeHtml(data.note || run.message || '')}</div>
        <div>
          <div class="field-label">回调地址（在快捷指令里 POST 结果）</div>
          <div class="flex gap-2">
            <input class="field mono !text-[0.68rem]" readonly value="${escapeHtml(callbackURL)}">
            <button class="btn btn-primary btn-sm" data-copy-callback>${icon('copy', 'w-3.5 h-3.5')}</button>
          </div>
        </div>
      </div>`,
    footer: `<button class="btn btn-primary" data-close>知道了</button>`
  });
  dialog.root.querySelector('[data-close]').addEventListener('click', dialog.close);
  dialog.root.querySelector('[data-copy-callback]').addEventListener('click', () => copyText(callbackURL));
}

function openButtonEditor(button) {
  const editing = Boolean(button);
  const dialog = modal({
    title: editing ? '编辑按钮' : '新增快捷指令按钮',
    content: `
      <div class="space-y-3">
        <div>
          <label class="field-label">按钮名称</label>
          <input id="btn-title" class="field" value="${escapeHtml(button?.title || '')}" placeholder="例如：晚安模式">
        </div>
        <div>
          <label class="field-label">快捷指令名称（必须与“快捷指令”App 中完全一致）</label>
          <input id="btn-shortcut" class="field" value="${escapeHtml(button?.shortcutName || '')}" placeholder="例如：Good Night">
        </div>
        <div>
          <label class="field-label">输入模板（可选，{{text}} 会替换为运行时的文本）</label>
          <input id="btn-template" class="field" value="${escapeHtml(button?.inputTemplate || '')}" placeholder="例如：房间=卧室&动作=关灯">
        </div>
        <div class="grid grid-cols-2 gap-3">
          <div>
            <label class="field-label">颜色</label>
            <input id="btn-color" type="color" class="field !p-1" value="${normalizeColor(button?.color || '#5B8DEF')}">
          </div>
          <div>
            <label class="field-label">单独冷却（秒，0 表示用全局）</label>
            <input id="btn-cooldown" type="number" min="0" max="3600" class="field" value="${Number(button?.cooldownSeconds || 0)}">
          </div>
        </div>
      </div>`,
    footer: `<button class="btn btn-ghost" data-cancel>取消</button><button class="btn btn-primary" data-save>${editing ? '保存' : '创建'}</button>`
  });
  dialog.root.querySelector('[data-cancel]').addEventListener('click', dialog.close);
  dialog.root.querySelector('[data-save]').addEventListener('click', async () => {
    const payload = {
      id: button?.id,
      title: dialog.root.querySelector('#btn-title').value.trim(),
      shortcutName: dialog.root.querySelector('#btn-shortcut').value.trim(),
      inputTemplate: dialog.root.querySelector('#btn-template').value.trim(),
      color: dialog.root.querySelector('#btn-color').value,
      cooldownSeconds: Number(dialog.root.querySelector('#btn-cooldown').value || 0),
      icon: button?.icon || 'bolt.fill'
    };
    if (!payload.title || !payload.shortcutName) {
      toast('按钮名称和快捷指令名称不能为空', 'error');
      return;
    }
    try {
      await api.dashSave(payload);
      dialog.close();
      toast(editing ? '已保存' : '已创建', 'success');
      await load();
    } catch (error) { toast(error.message, 'error'); }
  });
}

function renderRuns() {
  const container = document.getElementById('dash-runs');
  const count = document.getElementById('dash-run-count');
  if (count) count.textContent = `${dash.runs.length} 条`;
  if (!container) return;
  if (!dash.runs.length) {
    container.innerHTML = emptyState('还没有执行记录', '运行任意按钮后会在这里留下记录');
    return;
  }
  container.innerHTML = dash.runs.map((run) => {
    const color = run.status === 'completed' ? 'var(--success)' : run.status === 'failed' ? 'var(--danger)' : 'var(--warning)';
    return `
      <div class="file-row !items-start">
        <div class="w-2 h-2 rounded-full mt-2 flex-none" style="background:${color}"></div>
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2">
            <span class="text-[0.76rem] font-medium">${escapeHtml(run.buttonTitle)}</span>
            <span class="badge">${escapeHtml(run.status)}</span>
          </div>
          <div class="text-[0.64rem] muted mt-0.5">${escapeHtml(run.message || '')}</div>
          ${run.result ? `<div class="text-[0.64rem] mt-1 mono truncate" style="color:var(--muted-2)">${escapeHtml(run.result)}</div>` : ''}
        </div>
        <div class="text-[0.6rem] muted-2 flex-none">${escapeHtml(formatShortDate(run.createdAt))}</div>
      </div>`;
  }).join('');
}

function normalizeColor(value) {
  const text = String(value || '#5B8DEF');
  return /^#[0-9a-fA-F]{6}$/.test(text) ? text : '#5B8DEF';
}
