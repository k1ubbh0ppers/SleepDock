'use strict';

// Read-only lifecycle metadata. Conversation content and command arguments are
// never retained or returned to the renderer.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { promisify } = require('node:util');
const execFile = promisify(require('node:child_process').execFile);

const CATALOG = Object.freeze([
  { id: 'deepseek', name: 'DeepSeek Harness', processNames: ['deepseek harness', 'deepseek-harness', 'deepseek-harness.exe', 'deepseek harness.exe', 'dsh.exe'], commands: ['deepseek-harness', 'dsh'] },
  { id: 'codex', name: 'Codex', processNames: ['codex', 'codex.exe'], commands: ['codex'] },
  { id: 'workbuddy', name: 'WorkBuddy', processNames: ['workbuddy', 'workbuddy.exe'], commands: ['workbuddy'] },
  { id: 'muse', name: 'Muse', processNames: ['muse', 'muse.exe'], commands: ['muse'] },
  { id: 'claude', name: 'Claude Code', processNames: ['claude', 'claude.exe', 'claude code', 'claude-code'], commands: ['claude'] },
  { id: 'cindy', name: 'Cindy', processNames: ['cindy', 'cindy.exe'], commands: ['cindy'] }
]);
const defaultRun = (file, args) => execFile(file, args, { timeout: 8000, maxBuffer: 8 * 1024 * 1024, windowsHide: true });
const basename = value => path.win32.basename(path.posix.basename(String(value || ''))).toLowerCase();
const exists = value => { try { return Boolean(value) && fs.statSync(value).isFile(); } catch { return false; } };
const at = value => typeof value === 'number' ? value * 1000 : typeof value === 'string' ? Date.parse(value) : NaN;
const text = result => typeof result === 'string' ? result : String(result?.stdout || '');
const selectedSource = (selection, source) => source === '*' || selection.has(source);

function knownCLI(commandLine) {
  // Inspect only the executable and its first script argument. Matching words
  // later in an Agent prompt could otherwise manufacture a running Agent.
  const match = String(commandLine || '').match(/^(?:"[^"]*"|'[^']*'|\S+)\s+(?:"([^"]*)"|'([^']*)'|(\S+))/);
  const script = (match?.[1] || match?.[2] || match?.[3] || '').replaceAll('\\', '/').toLowerCase();
  if (script.endsWith('/@anthropic-ai/claude-code/cli.js')) return 'claude';
  if (script.endsWith('/@openai/codex/bin/codex.js')) return 'codex';
  return null;
}

function executableFromDesktop(file) {
  try {
    const content = fs.readFileSync(file, 'utf8');
    const match = content.match(/^TryExec=(.+)$/m) || content.match(/^Exec=(.+)$/m);
    if (!match) return null;
    // Desktop field codes are not commands, and are never passed to a shell.
    const parts = match[1].match(/"[^"\n]*"|'[^'\n]*'|[^\s]+/g) || [];
    let token = parts.shift()?.replace(/^["']|["']$/g, '');
    if (token === 'env') {
      while (parts.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(parts[0])) parts.shift();
      token = parts.shift()?.replace(/^["']|["']$/g, '');
    }
    return token && !token.startsWith('%') ? token : null;
  } catch { return null; }
}

function findOnPath(command, platform, env, home) {
  const delimiter = platform === 'win32' ? ';' : ':';
  const dirs = String(env.PATH || env.Path || '').split(delimiter).filter(Boolean);
  dirs.push(path.join(home, '.local', 'bin'));
  if (platform === 'win32') dirs.push(path.join(env.APPDATA || path.join(home, 'AppData', 'Roaming'), 'npm'));
  const suffixes = platform === 'win32' ? ['', '.exe', '.cmd', '.bat'] : [''];
  for (const dir of dirs) for (const suffix of suffixes) {
    const value = path.join(dir, command + suffix);
    if (exists(value)) return value;
  }
  return null;
}

async function processes(platform, run) {
  if (platform === 'win32') {
    const output = text(await run('tasklist.exe', ['/FO', 'CSV', '/NH']));
    if (/^ERROR:/im.test(output)) throw new Error('process list unavailable');
    const entries = output.split(/\r?\n/).filter(Boolean).map(line => {
      const match = line.match(/^"((?:[^"]|"")*)"/);
      return { name: (match ? match[1].replace(/""/g, '"') : line.trim()).toLowerCase(), executable: null };
    });
    if (entries.some(entry => entry.name === 'node.exe')) {
      try {
        const query = "Get-CimInstance Win32_Process -Filter \"Name = 'node.exe'\" | Select-Object Name,ExecutablePath,CommandLine | ConvertTo-Json -Compress";
        const raw = text(await run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', query])).trim();
        const records = raw ? JSON.parse(raw) : [];
        for (const record of Array.isArray(records) ? records : [records]) {
          if (typeof record?.CommandLine !== 'string') { entries.uncertainCLI = true; continue; }
          const source = knownCLI(record.CommandLine);
          if (source) entries.push({ name: 'node.exe', executable: record.ExecutablePath, source });
        }
      } catch { entries.uncertainCLI = true; }
    }
    return entries;
  }
  const output = text(await run('ps', ['-A', '-o', 'comm=,args=']));
  return output.split(/\r?\n/).filter(Boolean).map(line => {
    const match = line.trim().match(/^(\S+)\s+(.*)$/);
    if (!match) return { name: basename(line.trim()), executable: null };
    const args = match[2].match(/^"([^"]+)"|^(\S+)/);
    const name = basename(match[1]);
    return { name, executable: args?.[1] || args?.[2] || null, source: name === 'node' || name === 'nodejs' ? knownCLI(match[2]) : null };
  });
}

/** Discover known apps and explicitly selected executable/desktop files. */
async function discoverApps({ home = os.homedir(), platform = process.platform, run = defaultRun, env = process.env, customApps = [] } = {}) {
  let running = [], processError = false;
  try { running = await processes(platform, run); } catch { processError = true; }
  const desktopDirs = [path.join(home, '.local/share/applications'), '/usr/share/applications', '/usr/local/share/applications'];
  const desktopFiles = [];
  if (platform !== 'win32') for (const directory of desktopDirs) {
    try { for (const entry of fs.readdirSync(directory)) if (entry.endsWith('.desktop')) desktopFiles.push(path.join(directory, entry)); } catch { /* directory may not exist */ }
  }
  return [...CATALOG, ...customApps.filter(app => app && typeof app.id === 'string' && typeof app.path === 'string' && !CATALOG.some(known => known.id === app.id))].map(app => {
    let appPath = null;
    const names = app.processNames || [basename(app.path)];
    let customExecutable = app.path?.endsWith('.desktop') ? executableFromDesktop(app.path) : app.path;
    if (app.path && exists(app.path)) appPath = app.path;
    if (!appPath) for (const command of app.commands || []) {
      appPath = findOnPath(command, platform, env, home);
      if (appPath) break;
    }
    if (!appPath && platform === 'win32') {
      const local = env.LOCALAPPDATA || path.join(home, 'AppData/Local');
      const roots = [path.join(local, 'Programs'), local, env.ProgramFiles, env.PROGRAMFILES, env['ProgramFiles(x86)']].filter(Boolean);
      const folders = [app.name, app.id, app.name.replaceAll(' ', ''), app.id === 'deepseek' ? 'DeepSeek Harness' : app.name];
      for (const root of roots) for (const folder of folders) for (const name of names) {
        const candidate = path.join(root, folder, name.endsWith('.exe') ? name : name + '.exe');
        if (exists(candidate)) appPath ||= candidate;
      }
      if (app.id === 'claude') {
        const candidate = path.join(home, '.local', 'bin', 'claude.exe');
        if (exists(candidate)) appPath ||= candidate;
      }
    }
    if (!appPath && platform !== 'win32') {
      const desktop = desktopFiles.find(file => {
        const stem = basename(file).slice(0, -8);
        return stem === app.id || stem === app.name.toLowerCase() || stem.endsWith('.' + app.id) || (app.id === 'deepseek' && stem.includes('deepseek'));
      });
      if (desktop) appPath = desktop;
    }
    const executableNames = new Set([...names.map(value => value.toLowerCase()), ...(customExecutable ? [basename(customExecutable)] : [])]);
    const active = running.some(process => process.source === app.id || executableNames.has(process.name) || (process.executable && executableNames.has(basename(process.executable))));
    return { id: app.id, name: String(app.name || basename(app.path)).slice(0, 100), installed: Boolean(appPath) || active, running: active, path: appPath,
      mode: app.id === 'codex' ? 'lifecycle' : 'process', uncertain: processError || Boolean(running.uncertainCLI && ['codex', 'claude'].includes(app.id)) };
  });
}

class AgentMonitor {
  constructor({ home = os.homedir(), platform = process.platform, run = defaultRun, leaseDir = path.join(home, '.sleepdock', 'tasks'), env = process.env } = {}) {
    this.home = home; this.platform = platform; this.run = run; this.env = env; this.leaseDir = leaseDir;
    this.root = path.join(env.CODEX_HOME || path.join(home, '.codex'), 'sessions'); this.cursors = new Map(); this.leases = new Map();
    this.expired = new Set(); this.terminals = new Set(); this.since = null; this.lastScan = 0;
  }

  _discover(now, changes) {
    const full = !this.lastScan || now - this.lastScan >= 30000;
    if (full) this.lastScan = now;
    let directories = [this.root];
    if (!full) directories = [0, -86400000].map(delta => {
      const date = new Date(now + delta);
      return path.join(this.root, String(date.getFullYear()), String(date.getMonth() + 1).padStart(2, '0'), String(date.getDate()).padStart(2, '0'));
    });
    const found = new Set(); let entries = 0;
    const walk = (directory, depth = 0, recurse = true) => {
      let children;
      try { children = fs.readdirSync(directory, { withFileTypes: true }); }
      catch (error) { if (error.code !== 'ENOENT') changes.uncertain.add('codex'); return; }
      for (const item of children) {
        if (++entries > 30000 || depth > 12) { changes.uncertain.add('codex'); return; }
        if (item.name.startsWith('.')) continue;
        const file = path.join(directory, item.name);
        if (item.isDirectory() && recurse) walk(file, depth + 1);
        else if (item.isFile() && item.name.endsWith('.jsonl')) {
          try { if (now - fs.statSync(file).mtimeMs <= 86400000) found.add(file); }
          catch { changes.uncertain.add('codex'); }
        }
      }
    };
    if (!full) walk(this.root, 0, false);
    for (const directory of directories) walk(directory);
    return found;
  }

  _parse(line, cursor, now, changes) {
    const ordinal = cursor.ordinal++;
    if (!line.length) return;
    let object;
    try { object = JSON.parse(line); } catch { cursor.unknown = true; return; }
    const payload = object?.payload;
    if (!payload || typeof payload !== 'object') return;
    if (object.type === 'session_meta') {
      if (!cursor.identity) {
        cursor.identity = payload.id || cursor.file;
        cursor.created = at(payload.timestamp);
        cursor.boundary = Number.isInteger(payload.subagent_history_start_ordinal) ? payload.subagent_history_start_ordinal : null;
      }
      return;
    }
    if (cursor.boundary !== null && ordinal < cursor.boundary) return;
    if (object.type !== 'event_msg' || !['task_started', 'task_complete', 'turn_aborted'].includes(payload.type)) return;
    if (typeof payload.turn_id !== 'string' || !payload.turn_id) { cursor.unknown = true; return; }
    const began = at(payload.started_at), eventDate = at(object.timestamp);
    if (Number.isFinite(began) && Number.isFinite(cursor.created) && began < cursor.created - 1000) return;
    const id = payload.turn_id;
    if (payload.type === 'task_started') {
      cursor.active.set(id, { id, source: 'codex', label: 'Codex 任务', mode: 'lifecycle', startedAt: Number.isFinite(began) ? began : Number.isFinite(eventDate) ? eventDate : now });
    } else {
      if (!Number.isFinite(eventDate)) { cursor.unknown = true; return; }
      if (cursor.active.delete(id) && eventDate >= this.since) {
        if (payload.type === 'task_complete') changes.completed.set(id, 'codex');
        else changes.interrupted.add('codex');
      }
    }
  }

  _read(cursor, now, changes, budget) {
    let fd;
    try {
      fd = fs.openSync(cursor.file, 'r');
      const stat = fs.fstatSync(fd), identity = `${stat.dev}:${stat.ino}`;
      cursor.modified = stat.mtimeMs;
      if ((cursor.fileIdentity && cursor.fileIdentity !== identity) || stat.size < cursor.offset) {
        changes.uncertain.add('codex');
        if (cursor.active.size) changes.interrupted.add('codex');
        Object.assign(cursor, { offset: 0, remainder: Buffer.alloc(0), identity: null, created: NaN, boundary: null, unknown: false, ordinal: 0, active: new Map() });
      }
      cursor.fileIdentity = identity;
      if (stat.size <= cursor.offset) return;
      const count = Math.min(2 * 1024 * 1024, stat.size - cursor.offset, budget.remaining);
      if (count <= 0) { changes.uncertain.add('codex'); return; }
      const buffer = Buffer.allocUnsafe(count);
      const bytes = fs.readSync(fd, buffer, 0, count, cursor.offset);
      budget.remaining -= bytes; cursor.offset += bytes;
      const content = Buffer.concat([cursor.remainder, buffer.subarray(0, bytes)]);
      let start = 0, end;
      while ((end = content.indexOf(10, start)) >= 0) {
        this._parse(content.subarray(start, end).toString('utf8'), cursor, now, changes);
        start = end + 1;
      }
      cursor.remainder = Buffer.from(content.subarray(start));
      if (cursor.remainder.length > 8 * 1024 * 1024) {
        // Stop retaining a giant invalid record. Its newline must be reached
        // before parsing can safely resume, so keep this cursor uncertain.
        cursor.unknown = true; cursor.remainder = Buffer.alloc(0);
      }
      if (cursor.offset < stat.size) changes.uncertain.add('codex');
    } catch { changes.uncertain.add('codex'); }
    finally { if (fd !== undefined) fs.closeSync(fd); }
  }

  _leases(now, changes) {
    let files;
    try { files = fs.readdirSync(this.leaseDir); }
    catch (error) {
      if (error.code !== 'ENOENT') changes.uncertain.add('*');
      for (const lease of this.leases.values()) { changes.uncertain.add(lease.source); changes.interrupted.add(lease.source); }
      this.leases.clear(); return;
    }
    const seen = new Set();
    for (const file of files.filter(value => value.endsWith('.json'))) {
      let object;
      try {
        const filePath = path.join(this.leaseDir, file), stat = fs.lstatSync(filePath);
        if (!stat.isFile() || stat.size > 256 * 1024) throw new Error('invalid lease');
        object = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        if (!object || typeof object.id !== 'string' || !object.id) throw new Error('invalid lease id');
      } catch { changes.uncertain.add('*'); continue; }
      const id = object.id, previous = this.leases.get(id);
      const source = previous?.source || (typeof object.agentID === 'string' && object.agentID ? object.agentID : '*');
      seen.add(id);
      const heartbeat = at(object.heartbeatAt), fresh = Number.isFinite(heartbeat) && now - heartbeat >= -5000 && now - heartbeat <= 20000;
      if (object.state === 'complete' || object.state === 'aborted') {
        const first = !this.terminals.has(id); this.terminals.add(id);
        if (this.leases.delete(id)) {
          if (object.state === 'complete' && fresh && !this.expired.has(id)) changes.completed.set('lease:' + id, source);
          else changes.interrupted.add(source);
        } else if (object.state === 'aborted' && first && fresh && at(object.createdAt) >= this.since) changes.interrupted.add(source);
        continue;
      }
      let alive = false;
      if (Number.isInteger(object.pid) && object.pid > 0) {
        try { process.kill(object.pid, 0); alive = true; } catch (error) { alive = error.code === 'EPERM'; }
      }
      if (!fresh || !alive) {
        const wasRunning = this.leases.delete(id);
        if (wasRunning) changes.interrupted.add(source);
        if (wasRunning || !this.expired.has(id)) changes.uncertain.add(source);
        this.expired.add(id); continue;
      }
      this.expired.delete(id); this.terminals.delete(id);
      this.leases.set(id, { id: 'lease:' + id, source, label: String(object.name || '通用 Agent 任务').slice(0, 100), mode: 'lease', startedAt: at(object.createdAt) || now });
    }
    for (const [id, task] of this.leases) if (!seen.has(id)) {
      changes.uncertain.add(task.source); changes.interrupted.add(task.source); this.leases.delete(id); this.expired.add(id);
    }
  }

  async poll(selectedIds = CATALOG.map(app => app.id), customApps = [], now = Date.now()) {
    const selection = new Set(selectedIds), baseline = this.since === null;
    if (baseline) this.since = now;
    const changes = { completed: new Map(), interrupted: new Set(), uncertain: new Set() };
    for (const file of this._discover(now, changes)) if (!this.cursors.has(file)) this.cursors.set(file, { file, offset: 0, remainder: Buffer.alloc(0), identity: null, created: NaN, boundary: null, unknown: false, ordinal: 0, active: new Map(), modified: now });
    const active = new Map(), budget = { remaining: 16 * 1024 * 1024 };
    for (const [file, cursor] of this.cursors) {
      this._read(cursor, now, changes, budget);
      if (cursor.unknown || (cursor.active.size && now - cursor.modified > 1800000)) changes.uncertain.add('codex');
      for (const [id, task] of cursor.active) if (!active.has(id) || active.get(id).startedAt <= task.startedAt) active.set(id, task);
      if (!cursor.active.size && now - cursor.modified > 86400000) this.cursors.delete(file);
    }
    this._leases(now, changes);
    for (const task of this.leases.values()) active.set(task.id, task);
    const apps = await discoverApps({ home: this.home, platform: this.platform, run: this.run, env: this.env, customApps });
    for (const app of apps) {
      if (app.uncertain) changes.uncertain.add(app.id);
      if (app.id === 'codex' && app.running && !fs.existsSync(this.root)) changes.uncertain.add('codex');
      if (app.running && app.id !== 'codex') active.set('app:' + app.id, { id: 'app:' + app.id, source: app.id, label: app.name + ' · 运行保护', mode: 'process', startedAt: now });
    }
    const tasks = [...active.values()].filter(task => selectedSource(selection, task.source));
    // A completion from an unselected source must not arm the selected batch.
    return { tasks, completedTaskIDs: baseline ? [] : [...changes.completed].filter(([, source]) => selectedSource(selection, source)).map(([id]) => id),
      interruptedSources: baseline ? [] : [...changes.interrupted].filter(source => selectedSource(selection, source)),
      uncertainSources: [...changes.uncertain].filter(source => selectedSource(selection, source)), apps, timestamp: now };
  }
}

module.exports = { CATALOG, AgentMonitor, discoverApps };
