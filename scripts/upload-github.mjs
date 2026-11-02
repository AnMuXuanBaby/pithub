/**
 * 用 GitHub REST API 上传 PitHub 工程（不依赖本机 Git）。
 *
 * 用法：
 *   GITHUB_TOKEN=github_pat_xxx \
 *   GITHUB_REPO=yourname/pithub \
 *   node scripts/upload-github.mjs
 *
 * 可选：
 *   GITHUB_BRANCH=main      目标分支（默认 main）
 *   GITHUB_CREATE=1         仓库不存在时尝试创建（仅个人账号）
 *
 * Token 权限：
 *   - Fine-grained PAT：Contents: Read/Write + Workflows: Read/Write
 *   - Classic PAT：repo + workflow
 *
 * 成功后 GitHub Actions 会自动构建未签名 IPA 并发布 Release `PitHub-Latest`。
 * Token 只从环境变量读取，不会写入文件或日志。
 */

import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const TOKEN = process.env.GITHUB_TOKEN || '';
let REPO = process.env.GITHUB_REPO || '';
const REPO_NAME = process.env.GITHUB_REPO_NAME || 'pithub';
const BRANCH = process.env.GITHUB_BRANCH || 'main';
const CREATE = process.env.GITHUB_CREATE === '1' || Boolean(process.env.GITHUB_REPO_NAME);
const API = 'https://api.github.com';

const EXCLUDED_DIRS = new Set([
  '.git', '.build', 'build', 'DerivedData', 'node_modules', 'PitHub.xcodeproj',
  'dist', 'PhotoNAS', '.trae', 'certificates', 'Payload'
]);
const EXCLUDED_FILES = new Set([
  '.DS_Store', 'build.log', 'package-lock.json'
]);

if (!TOKEN) {
  console.error('缺少 GITHUB_TOKEN。');
  process.exit(1);
}

async function gh(pathname, options = {}) {
  const response = await fetch(API + pathname, {
    ...options,
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      'User-Agent': 'PitHub-Uploader',
      ...(options.headers || {})
    }
  });
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch {}
  if (!response.ok) {
    const message = (data && data.message) || text;
    throw new Error(`${options.method || 'GET'} ${pathname} → ${response.status}: ${message}`);
  }
  return data;
}

function collectFiles(root, relative = '') {
  const result = [];
  const entries = fs.readdirSync(path.join(root, relative), { withFileTypes: true });
  for (const entry of entries) {
    const rel = relative ? `${relative}/${entry.name}` : entry.name;
    if (entry.isDirectory()) {
      if (EXCLUDED_DIRS.has(entry.name)) continue;
      result.push(...collectFiles(root, rel));
    } else if (entry.isFile()) {
      if (EXCLUDED_FILES.has(entry.name)) continue;
      if (entry.name.endsWith('.ipa') || entry.name.endsWith('.log') || entry.name.endsWith('.xcarchive')) continue;
      result.push(rel);
    }
  }
  return result;
}

async function main() {
  const user = await gh('/user');
  console.log(`GitHub 用户：${user.login}`);
  if (!REPO) {
    REPO = `${user.login}/${REPO_NAME}`;
    console.log(`未指定 GITHUB_REPO，使用 ${REPO}`);
  }
  if (!REPO.includes('/')) {
    throw new Error('GITHUB_REPO 格式应为 owner/repo。');
  }

  let repoInfo;
  try {
    repoInfo = await gh(`/repos/${REPO}`);
  } catch (error) {
    if (!CREATE) {
      throw new Error(`仓库 ${REPO} 不存在或无权访问。若想创建，请加 GITHUB_CREATE=1（只能创建到当前用户名下）。`);
    }
    const name = REPO.split('/')[1];
    repoInfo = await gh('/user/repos', {
      method: 'POST',
      body: JSON.stringify({
        name,
        private: process.env.GITHUB_PRIVATE === '1',
        auto_init: false,
        description: 'PitHub · 家庭私有微型服务器'
      })
    });
    console.log(`已创建仓库：${repoInfo.html_url}`);
  }
  console.log(`仓库：${repoInfo.full_name}，默认分支：${repoInfo.default_branch}`);

  const branch = repoInfo.default_branch || BRANCH;
  let parentSha = null;
  let baseTree = null;
  try {
    const ref = await gh(`/repos/${REPO}/git/ref/heads/${branch}`);
    parentSha = ref.object.sha;
    const parent = await gh(`/repos/${REPO}/git/commits/${parentSha}`);
    baseTree = parent.tree.sha;
    console.log(`已有分支 ${branch}，父提交 ${parentSha.slice(0, 8)}`);
  } catch (error) {
    console.log(`空仓库，先通过 Contents API 创建初始提交…`);
    await gh(`/repos/${REPO}/contents/.pithub-init`, {
      method: 'PUT',
      body: JSON.stringify({
        message: 'chore: initialize repository',
        content: Buffer.from('PitHub').toString('base64'),
        branch
      })
    });
    const ref = await gh(`/repos/${REPO}/git/ref/heads/${branch}`);
    parentSha = ref.object.sha;
    // 不使用 base_tree：最终提交只包含本工程文件，移除占位文件
    baseTree = null;
    console.log(`已创建初始提交 ${parentSha.slice(0, 8)}`);
  }

  const root = process.cwd();
  const files = collectFiles(root).sort();
  console.log(`准备上传 ${files.length} 个文件…`);

  const treeEntries = [];
  let index = 0;
  for (const relative of files) {
    index += 1;
    const absolute = path.join(root, relative);
    const content = fs.readFileSync(absolute).toString('base64');
    const blob = await gh(`/repos/${REPO}/git/blobs`, {
      method: 'POST',
      body: JSON.stringify({ content, encoding: 'base64' })
    });
    treeEntries.push({ path: relative, mode: '100644', type: 'blob', sha: blob.sha });
    if (index % 10 === 0 || index === files.length) {
      console.log(`  已上传 ${index}/${files.length}`);
    }
  }

  const tree = await gh(`/repos/${REPO}/git/trees`, {
    method: 'POST',
    body: JSON.stringify({ tree: treeEntries, ...(baseTree ? { base_tree: baseTree } : {}) })
  });
  console.log(`tree: ${tree.sha}`);

  const commitBody = {
    message: 'PitHub 1.0.0：原生 HTTP / FilePit / PhotoNode / ClipHub / DashLink / 内嵌网页前端',
    tree: tree.sha,
    ...(parentSha ? { parents: [parentSha] } : {})
  };
  const commit = await gh(`/repos/${REPO}/git/commits`, {
    method: 'POST',
    body: JSON.stringify(commitBody)
  });
  console.log(`commit: ${commit.sha}`);

  if (parentSha) {
    await gh(`/repos/${REPO}/git/refs/heads/${branch}`, {
      method: 'PATCH',
      body: JSON.stringify({ sha: commit.sha, force: false })
    });
  } else {
    await gh(`/repos/${REPO}/git/refs`, {
      method: 'POST',
      body: JSON.stringify({ ref: `refs/heads/${branch}`, sha: commit.sha })
    });
  }

  console.log('');
  console.log(`完成：https://github.com/${REPO}/commit/${commit.sha}`);
  console.log(`Actions：https://github.com/${REPO}/actions`);
  console.log(`Release：https://github.com/${REPO}/releases/tag/PitHub-Latest`);
}

main().catch((error) => {
  console.error('');
  console.error('上传失败：' + error.message);
  if (/workflow|scope/i.test(error.message)) {
    console.error('提示：PAT 需要 Contents 读写 + Workflows 读写（Fine-grained）或 repo + workflow（Classic）。');
  }
  process.exit(1);
});
