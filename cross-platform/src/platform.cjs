'use strict';

const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { execFile, spawn: spawnProcess } = require('node:child_process');
const { promisify } = require('node:util');
const { EventEmitter } = require('node:events');

const execFileAsync = promisify(execFile);
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));
const defaultRun = (file, args, options = {}) => execFileAsync(file, args, {
  timeout: 10000, maxBuffer: 256 * 1024, windowsHide: true, encoding: 'utf8', ...options,
});

function executable(name, env = process.env, platform = process.platform) {
  const separator = platform === 'win32' ? ';' : path.delimiter;
  const extensions = platform === 'win32' ? ['', '.exe', '.cmd'] : [''];
  for (const directory of (env.PATH || env.Path || '').split(separator).filter(Boolean)) {
    for (const extension of extensions) {
      const file = path.join(directory, name + extension);
      try { fs.accessSync(file, platform === 'win32' ? fs.constants.F_OK : fs.constants.X_OK); return file; } catch {}
    }
  }
  return null;
}

/** Native power actions. Lifecycle inhibition itself is owned by Electron's powerSaveBlocker. */
class PlatformPower extends EventEmitter {
  constructor({ platform = process.platform, run = defaultRun, spawn = spawnProcess,
    resourcesDir = path.join(__dirname, '..', 'resources'), electronPowerMonitor,
    pid = process.pid, stateDir = path.join(os.homedir(), '.sleepdock', 'power'),
    env = process.env, sysRoot = '/', onError = null } = {}) {
    super();
    Object.assign(this, { platform, run, spawn, resourcesDir, electronPowerMonitor, pid, stateDir, env, sysRoot, onError });
    this.lidMode = 'system';
    this.guard = null;
    this.generation = 0;
    this.queue = Promise.resolve();
    this.linuxLidDetected = null;
    this.windowsStatus = null;
    this.windowsStatusAt = 0;
    this.powershell = env.SystemRoot
      ? path.win32.join(env.SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe') : 'powershell.exe';
  }

  _root(relative) { return path.join(this.sysRoot, relative.replace(/^\//, '')); }

  capabilities() {
    if (this.platform === 'win32') return {
      sleep: true, displayOff: true, lock: true, lidKeepAwake: true, lidSleep: true,
      blur: 'Windows 11 原生磨砂；旧系统使用半透明背景',
      notes: ['Windows 合盖模式会临时修改当前电源方案的 AC/DC 合盖动作；需单独确认，退出恢复原值。',
        '合盖保持运行仅在接电时启用；权限不足会报错，不自动提权。'],
    };
    if (this.platform === 'linux') {
      const logind = fs.existsSync(this._root('/run/systemd/system')) && fs.existsSync(this._root('/run/dbus/system_bus_socket'));
      const systemctl = executable('systemctl', this.env, 'linux');
      const inhibitor = executable('systemd-inhibit', this.env, 'linux');
      const loginctl = executable('loginctl', this.env, 'linux');
      const x11 = Boolean(this.env.DISPLAY && !this.env.WAYLAND_DISPLAY);
      const lidAvailable = this.linuxLidDetected === null ? this._hasACPILid() : this.linuxLidDetected;
      return {
        sleep: Boolean(logind && systemctl), displayOff: Boolean(x11 && executable('xset', this.env, 'linux')),
        lock: Boolean(logind && loginctl), lidKeepAwake: Boolean(logind && inhibitor),
        lidSleep: Boolean(logind && systemctl && lidAvailable),
        blur: '半透明背景；系统级背景模糊取决于桌面合成器',
        notes: ['Linux 合盖保护使用 logind 临时抑制器；桌面管理器持有合盖控制时可能覆盖此行为。',
          ...(!lidAvailable ? ['当前未读取到合盖传感器，主动合盖休眠不可选；系统默认策略仍有效。'] : []),
          ...(this.env.WAYLAND_DISPLAY ? ['Wayland 没有统一的熄屏接口，已禁用熄屏按钮。'] : []),
          ...(!logind ? ['当前缺少可用的 systemd/logind 会话，系统电源操作不可用。'] : [])],
      };
    }
    return { sleep: false, displayOff: false, lock: false, lidKeepAwake: false, lidSleep: false,
      blur: '半透明背景', notes: ['此运行包仅提供 Windows / Linux 系统电源接口。macOS 请使用原生版本。'] };
  }

  async _ps(action, more = []) {
    let stdout;
    try {
      ({ stdout } = await this.run(this.powershell, ['-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'Bypass', '-File', path.join(this.resourcesDir, 'windows-power.ps1'),
        '-Action', action, ...more]));
    } catch (error) {
      let detail;
      try { detail = JSON.parse(String(error.stdout || '').replace(/^\uFEFF/, '').trim()).message; } catch {}
      throw new Error(detail || `Windows 电源操作失败：${error.message}`);
    }
    const text = String(stdout || '').replace(/^\uFEFF/, '').trim();
    if (!text) throw new Error('Windows 电源接口没有返回结果。');
    let result;
    try { result = JSON.parse(text); } catch { throw new Error('Windows 电源接口返回格式无效。'); }
    if (!result.ok) throw new Error(result.message || 'Windows 拒绝了电源操作。');
    return result;
  }

  async status() {
    let idleSeconds = null;
    try {
      const value = this.electronPowerMonitor?.getSystemIdleTime();
      if (Number.isFinite(value) && value >= 0) idleSeconds = value;
    } catch {}
    let result = { battery: -1, pluggedIn: null, idleSeconds, lidClosed: null, lidMode: this.lidMode };
    if (this.platform === 'win32') {
      // Native calls are deliberately read-only; status failure never means "on AC".
      try {
        let status = this.windowsStatus;
        const fresh = !status || Date.now() - this.windowsStatusAt >= 5000;
        if (fresh) {
          status = await this._ps('Status');
          this.windowsStatus = status;
          this.windowsStatusAt = Date.now();
        }
        result = { ...result, battery: status.battery >= 0 && status.battery <= 100 ? status.battery : -1,
          pluggedIn: typeof status.pluggedIn === 'boolean' ? status.pluggedIn : null,
          // A cached keyboard-idle reading must never trigger a sleep after new input.
          idleSeconds: idleSeconds ?? (fresh && Number.isFinite(status.idleSeconds) ? status.idleSeconds : null) };
      } catch (error) { result.error = error.message; }
    } else if (this.platform === 'linux') {
      result = { ...result, ...await this._linuxStatus() };
      this.linuxLidDetected = typeof result.lidClosed === 'boolean';
    }
    if (this.guard?.platform === 'win32') {
      try {
        const state = JSON.parse(await fsp.readFile(this.guard.statusFile, 'utf8'));
        if (state.token === this.guard.token && !['active', 'applying'].includes(state.status) && !this.guard.stopping) {
          this._guardFailed(state.message || '合盖守护已恢复系统设置，请重新启用。');
        }
      } catch {}
    }
    result.lidMode = this.lidMode;
    result.capabilities = this.capabilities();
    return result;
  }

  _hasACPILid() {
    try { return fs.readdirSync(this._root('/proc/acpi/button/lid')).some(name => fs.existsSync(this._root(`/proc/acpi/button/lid/${name}/state`))); }
    catch { return false; }
  }

  async _linuxStatus() {
    const read = async file => (await fsp.readFile(file, 'utf8')).trim();
    let names = [];
    try { names = await fsp.readdir(this._root('/sys/class/power_supply')); } catch {}
    const capacities = [], online = [], statuses = [];
    for (const name of names) {
      const dir = this._root(`/sys/class/power_supply/${name}`);
      let type;
      try { type = await read(path.join(dir, 'type')); } catch { continue; }
      if (type === 'Battery') {
        try { const c = Number(await read(path.join(dir, 'capacity'))); if (Number.isFinite(c) && c >= 0 && c <= 100) capacities.push(c); } catch {}
        try { statuses.push(await read(path.join(dir, 'status'))); } catch {}
      } else {
        try { const value = await read(path.join(dir, 'online')); if (value === '0' || value === '1') online.push(value === '1'); } catch {}
      }
    }
    let lidClosed = null;
    try {
      for (const name of await fsp.readdir(this._root('/proc/acpi/button/lid'))) {
        const text = await read(this._root(`/proc/acpi/button/lid/${name}/state`));
        if (/\bclosed\b/i.test(text)) { lidClosed = true; break; }
        if (/\bopen\b/i.test(text)) lidClosed = false;
      }
    } catch {}
    if (lidClosed === null && executable('busctl', this.env, 'linux')) {
      try {
        const { stdout } = await this.run('busctl', ['--system', 'get-property', 'org.freedesktop.UPower',
          '/org/freedesktop/UPower', 'org.freedesktop.UPower', 'LidIsPresent']);
        if (/^b\s+true\s*$/.test(stdout.trim())) {
          const value = await this.run('busctl', ['--system', 'get-property', 'org.freedesktop.UPower',
            '/org/freedesktop/UPower', 'org.freedesktop.UPower', 'LidIsClosed']);
          if (/^b\s+(true|false)\s*$/.test(value.stdout.trim())) lidClosed = /true/.test(value.stdout);
        }
      } catch {}
    }
    return { battery: capacities.length ? Math.round(capacities.reduce((a, b) => a + b, 0) / capacities.length) : -1,
      pluggedIn: online.length ? online.some(Boolean) : statuses.includes('Charging') ? true
        : statuses.includes('Discharging') ? false : null, lidClosed };
  }

  async sleep() {
    if (!this.capabilities().sleep) throw new Error('当前系统没有可用的休眠接口。');
    if (this.platform === 'win32') return this._ps('Sleep');
    await this.run('systemctl', ['suspend']);
    return { ok: true };
  }
  async displayOff() {
    if (!this.capabilities().displayOff) throw new Error('当前桌面没有可用的熄屏接口。');
    if (this.platform === 'win32') return this._ps('DisplayOff');
    await this.run('xset', ['dpms', 'force', 'off']);
    return { ok: true };
  }
  async lock() {
    if (!this.capabilities().lock) throw new Error('当前会话没有可用的锁屏接口。');
    if (this.platform === 'win32') return this._ps('Lock');
    await this.run('loginctl', ['lock-session']);
    return { ok: true };
  }

  setLidMode(mode) {
    if (!['system', 'keep', 'sleep'].includes(mode)) return Promise.reject(new Error('无效的合盖模式。'));
    const generation = ++this.generation;
    const operation = async () => {
      if (generation !== this.generation && mode !== 'system') return { ok: false, message: '合盖请求已取消。', mode: this.lidMode };
      if (mode === this.lidMode && mode !== 'system' && (this.guard || this.platform === 'linux')) return { ok: true, mode };
      await this._stopGuard();
      if (mode === 'system') {
        if (this.platform === 'win32' && fs.existsSync(path.join(this.stateDir, 'state.json'))) {
          await this._ps('LidRestore', ['-StateDir', this.stateDir]);
        }
        this.lidMode = 'system';
        return { ok: true, mode };
      }
      const caps = this.capabilities();
      if ((mode === 'keep' && !caps.lidKeepAwake) || (mode === 'sleep' && !caps.lidSleep)) {
        throw new Error('当前系统不支持所选合盖模式。');
      }
      if (mode === 'keep') {
        const power = await this.status();
        if (power.pluggedIn !== true) throw new Error('合盖保持运行需要接通电源；当前未确认已接电。');
      }
      if (this.platform === 'win32') await this._startWindowsGuard(mode, generation);
      else if (mode === 'keep') await this._startLinuxGuard(generation);
      if (generation !== this.generation) { await this._stopGuard(); return { ok: false, message: '合盖请求已取消。', mode: 'system' }; }
      this.lidMode = mode;
      return { ok: true, mode, message: mode === 'keep' ? '合盖保持运行已启用；退出或失联后释放。' : '合盖休眠已启用。' };
    };
    const result = this.queue.then(operation);
    this.queue = result.catch(() => {});
    return result;
  }

  async _makeLease() {
    await fsp.mkdir(this.stateDir, { recursive: true, mode: 0o700 });
    if ((await fsp.lstat(this.stateDir)).isSymbolicLink()) throw new Error('合盖守护目录不能是符号链接。');
    const token = crypto.randomUUID();
    const lease = path.join(this.stateDir, `${token}.lease`);
    const update = async () => {
      const temporary = lease + '.new';
      await fsp.writeFile(temporary, `${token}\n${Date.now()}\n`, { mode: 0o600, flag: 'w' });
      await fsp.rename(temporary, lease);
    };
    await update();
    return { token, lease, update };
  }

  _startHeartbeat(guard) {
    guard.timer = setInterval(() => {
      if (this.guard !== guard || guard.stopping) return;
      guard.pendingHeartbeat = guard.update().catch(error => {
        if (this.guard === guard && !guard.stopping) this._guardFailed(`合盖心跳失败：${error.message}`);
      });
    }, 4000);
    guard.timer.unref?.();
  }

  _guardFailed(message) {
    const guard = this.guard;
    if (!guard || guard.stopping) return;
    guard.stopping = true;
    clearInterval(guard.timer);
    fsp.rm(guard.lease, { force: true }).catch(() => {});
    this.lidMode = 'system';
    // Keep the guard reference until restoration is observed by _stopGuard.
    this.emit('failure', new Error(message));
    if (typeof this.onError === 'function') this.onError(message);
  }

  async _startWindowsGuard(mode, generation) {
    const lease = await this._makeLease();
    const guard = { ...lease, platform: 'win32', stopping: false,
      statusFile: path.join(this.stateDir, `${lease.token}.status.json`) };
    const child = this.spawn(this.powershell, ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-File', path.join(this.resourcesDir, 'windows-power.ps1'), '-Action', 'LidGuard', '-Mode', mode,
      '-ParentPid', String(this.pid), '-Lease', lease.lease, '-Token', lease.token, '-StateDir', this.stateDir],
    { windowsHide: true, detached: true, stdio: ['ignore', 'ignore', 'pipe'] });
    guard.child = child;
    guard.stderr = '';
    child.stderr?.on('data', data => { guard.stderr = (guard.stderr + data.toString()).slice(-3000); });
    child.on('error', error => { guard.spawnError = error; });
    child.on('exit', (code) => {
      guard.exited = true;
      if (this.guard === guard && !guard.stopping && this.lidMode !== 'system') {
        this._guardFailed(`Windows 合盖守护已退出（${code}）；请查看恢复状态。`);
      }
    });
    child.unref?.();
    this.guard = guard;
    this._startHeartbeat(guard);
    try {
      const deadline = Date.now() + 25000;
      while (Date.now() < deadline) {
        if (generation !== this.generation) throw new Error('合盖请求已取消。');
        if (guard.spawnError) throw guard.spawnError;
        try {
          const status = JSON.parse(await fsp.readFile(guard.statusFile, 'utf8'));
          if (status.token !== guard.token) throw Object.assign(new Error('合盖守护返回了其他请求的状态。'), { guardError: true });
          if (status.status === 'active') return;
          if (['error', 'restored'].includes(status.status)) throw Object.assign(new Error(status.message || '合盖设置没有保持生效。'), { guardError: true });
        } catch (error) { if (error.guardError) throw error; }
        if (guard.exited) throw new Error(guard.stderr.trim() || '合盖守护未能启动；可能需要管理员权限。');
        await pause(150);
      }
      throw new Error('未收到合盖守护确认，已取消请求并等待恢复。');
    } catch (error) { await this._stopGuard(); throw error; }
  }

  async _startLinuxGuard(generation) {
    const lease = await this._makeLease();
    const guard = { ...lease, platform: 'linux', stopping: false };
    this.guard = guard;
    let child;
    try {
      child = this.spawn('systemd-inhibit', ['--what=handle-lid-switch', '--mode=block', '--who=SleepDock',
        '--why=SleepDock 合盖保持运行', '--', '/bin/sh', path.join(this.resourcesDir, 'linux-lid-watchdog.sh'),
        String(this.pid), lease.lease, lease.token], { stdio: ['ignore', 'pipe', 'pipe'], detached: true });
      guard.child = child;
      guard.stderr = '';
      const ready = new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('logind 没有确认合盖保护。')), 7000);
        let text = '';
        child.stdout?.on('data', data => {
          text = (text + data.toString()).slice(-500);
          if (text.includes('SLEEPDOCK_INHIBIT_READY')) { clearTimeout(timer); resolve(); }
        });
        child.stderr?.on('data', data => { guard.stderr = (guard.stderr + data.toString()).slice(-2000); });
        child.on('error', error => { clearTimeout(timer); reject(error); });
        child.on('exit', code => {
          guard.exited = true;
          clearTimeout(timer);
          reject(new Error(guard.stderr || `logind 合盖保护已退出（${code}）。`));
          if (this.guard === guard && !guard.stopping && this.lidMode !== 'system') this._guardFailed('logind 合盖保护已结束。');
        });
      });
      this._startHeartbeat(guard);
      child.unref?.();
      await ready;
      if (generation !== this.generation) throw new Error('合盖请求已取消。');
    } catch (error) { await this._stopGuard(); throw error; }
  }

  async _stopGuard() {
    const guard = this.guard;
    this.lidMode = 'system';
    if (!guard) return;
    guard.stopping = true;
    clearInterval(guard.timer);
    await guard.pendingHeartbeat;
    await fsp.rm(guard.lease, { force: true });
    const deadline = Date.now() + 12000;
    if (guard.platform === 'win32') {
      while (Date.now() < deadline) {
        try {
          const state = JSON.parse(await fsp.readFile(guard.statusFile, 'utf8'));
          if (state.token === guard.token && state.status === 'restored') {
            this.guard = null;
            await fsp.rm(guard.statusFile, { force: true });
            return;
          }
          if (state.token === guard.token && state.status === 'error' && state.restoreFailed) {
            throw Object.assign(new Error(state.message || '合盖原值恢复失败；恢复记录已保留。'), { restoreFailed: true });
          }
        } catch (error) { if (error.restoreFailed) throw error; }
        if (guard.exited) break;
        await pause(150);
      }
      // A killed guard cannot clean up itself. Recover only its saved scheme/values.
      try {
        await this._ps('LidRestore', ['-StateDir', this.stateDir]);
        this.guard = null;
        await fsp.rm(guard.statusFile, { force: true });
      } catch (error) { throw new Error(`合盖原值恢复未确认：${error.message}。记录：${this.stateDir}`); }
    } else {
      // Removing the lease makes the independent child exit even if this process is killed now.
      while (!guard.exited && Date.now() < deadline) await pause(100);
      if (!guard.exited) guard.child?.kill('SIGTERM');
      this.guard = null;
    }
  }

  async shutdown() {
    await this.setLidMode('system');
  }
}

module.exports = { PlatformPower, executable };
