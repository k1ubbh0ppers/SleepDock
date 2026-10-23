'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');
const { EventEmitter } = require('node:events');
const { PassThrough } = require('node:stream');
const { PlatformPower } = require('../src/platform.cjs');

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'sleepdock-power-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  return root;
}

async function write(root, file, text) {
  const target = path.join(root, file.replace(/^\//, ''));
  await fs.mkdir(path.dirname(target), { recursive: true });
  await fs.writeFile(target, text);
  return target;
}

async function linuxFixture(t, { lid = 'open', wayland = false } = {}) {
  const root = await fixture(t);
  const bin = path.join(root, 'bin');
  await fs.mkdir(bin);
  for (const command of ['systemctl', 'systemd-inhibit', 'loginctl', 'xset']) {
    const file = await write(root, `bin/${command}`, '#!/bin/sh\nexit 0\n');
    await fs.chmod(file, 0o700);
  }
  await fs.mkdir(path.join(root, 'run/systemd/system'), { recursive: true });
  await write(root, '/run/dbus/system_bus_socket', 'fake socket');
  if (lid !== null) await write(root, '/proc/acpi/button/lid/LID0/state', `state: ${lid}\n`);
  const calls = [];
  const power = new PlatformPower({ platform: 'linux', sysRoot: root,
    env: { PATH: bin, DISPLAY: ':0', ...(wayland ? { WAYLAND_DISPLAY: 'wayland-0' } : {}) },
    stateDir: path.join(root, 'state'), electronPowerMonitor: { getSystemIdleTime: () => 42 },
    run: async (file, args) => { calls.push([file, args]); return { stdout: '' }; } });
  return { power, root, calls };
}

test('Windows status uses read-only helper, preserves unknown power and Electron idle', async () => {
  const calls = [];
  const power = new PlatformPower({ platform: 'win32', env: { SystemRoot: 'C:\\Windows' },
    electronPowerMonitor: { getSystemIdleTime: () => 35 },
    run: async (file, args) => { calls.push([file, args]); return { stdout: JSON.stringify({ ok: true, battery: 81, pluggedIn: null, idleSeconds: 9 }) }; } });
  const result = await power.status();
  assert.equal(result.battery, 81);
  assert.equal(result.pluggedIn, null);
  assert.equal(result.idleSeconds, 35);
  assert.equal(result.lidClosed, null);
  assert.equal(calls[0][0], 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe');
  assert.equal(calls[0][1].at(-1), 'Status');
});

test('Windows status failures never become AC power or zero idle', async () => {
  const power = new PlatformPower({ platform: 'win32', run: async () => { throw new Error('denied'); } });
  const result = await power.status();
  assert.equal(result.battery, -1);
  assert.equal(result.pluggedIn, null);
  assert.equal(result.idleSeconds, null);
  assert.match(result.error, /denied/);
});

test('Windows status caches only power metadata; native idle is never reused', async () => {
  let count = 0;
  const power = new PlatformPower({ platform: 'win32', run: async () => {
    count++; return { stdout: '{"ok":true,"battery":70,"pluggedIn":true,"idleSeconds":200}' };
  } });
  assert.equal((await power.status()).idleSeconds, 200);
  const cached = await power.status();
  assert.equal(cached.idleSeconds, null); assert.equal(cached.battery, 70); assert.equal(count, 1);
});

test('PowerShell powercfg calls bind the entire argument array explicitly', async () => {
  const source = await fs.readFile(path.join(__dirname, '../resources/windows-power.ps1'), 'utf8');
  const calls = source.split('\n').filter(line => /Run-PowerCfg\s/.test(line) && !/^function /.test(line));
  assert.equal(calls.length, 5);
  assert.ok(calls.every(line => /Run-PowerCfg -Arguments @\(/.test(line)));
  assert.ok(source.includes('EnableSuspendPrivilege()'));
});

test('Windows helper rejection reports native failure instead of success', async () => {
  const power = new PlatformPower({ platform: 'win32', run: async () => ({ stdout: '{"ok":false,"message":"permission denied"}' }) });
  await assert.rejects(power.sleep(), /permission denied/);
});

test('Windows helper nonzero exit preserves its structured error', async () => {
  const power = new PlatformPower({ platform: 'win32', run: async () => {
    throw Object.assign(new Error('exit 1'), { stdout: '{"ok":false,"message":"restore failed"}' });
  } });
  await assert.rejects(power.lock(), /restore failed/);
});

test('Windows actions use one fixed helper with arguments, never a shell string', async () => {
  const calls = [];
  const power = new PlatformPower({ platform: 'win32', resourcesDir: '/App with spaces/resources',
    run: async (file, args) => { calls.push([file, args]); return { stdout: '{"ok":true}' }; } });
  await power.sleep(); await power.displayOff(); await power.lock();
  assert.deepEqual(calls.map(x => x[1].at(-1)), ['Sleep', 'DisplayOff', 'Lock']);
  assert.ok(calls.every(x => x[1].includes('/App with spaces/resources/windows-power.ps1')));
});

test('keep lid mode refuses unknown or disconnected AC before spawning', async t => {
  for (const pluggedIn of [null, false]) {
    const root = await fixture(t);
    let spawned = false;
    const power = new PlatformPower({ platform: 'win32', stateDir: root,
      run: async () => ({ stdout: JSON.stringify({ ok: true, battery: 40, pluggedIn }) }),
      spawn: () => { spawned = true; throw new Error('must not spawn'); } });
    await assert.rejects(power.setLidMode('keep'), /接通电源/);
    assert.equal(spawned, false);
  }
});

test('Windows startup system mode restores an old persisted snapshot', async t => {
  const root = await fixture(t);
  await fs.writeFile(path.join(root, 'state.json'), '{}');
  const calls = [];
  const power = new PlatformPower({ platform: 'win32', stateDir: root, run: async (file, args) => {
    calls.push(args); await fs.rm(path.join(root, 'state.json')); return { stdout: '{"ok":true}' };
  } });
  const result = await power.setLidMode('system');
  assert.equal(result.ok, true);
  assert.ok(calls[0].includes('LidRestore'));
});

test('Linux capabilities disable unsupported Wayland display off', async t => {
  const { power } = await linuxFixture(t, { wayland: true });
  assert.equal(power.capabilities().displayOff, false);
  assert.equal(power.capabilities().sleep, true);
  assert.equal(power.capabilities().lidSleep, true);
  await assert.rejects(power.displayOff(), /熄屏接口/);
});

test('Linux session without logind disables native power actions', async t => {
  const root = await fixture(t);
  const power = new PlatformPower({ platform: 'linux', sysRoot: root, env: { PATH: '' } });
  const caps = power.capabilities();
  assert.equal(caps.sleep, false); assert.equal(caps.lock, false); assert.equal(caps.lidKeepAwake, false);
  await assert.rejects(power.sleep(), /休眠接口/);
});

test('Linux reads battery, adapter, lid state, and idle without executing mutations', async t => {
  const { power, root, calls } = await linuxFixture(t, { lid: 'closed' });
  await write(root, '/sys/class/power_supply/BAT0/type', 'Battery\n');
  await write(root, '/sys/class/power_supply/BAT0/capacity', '57\n');
  await write(root, '/sys/class/power_supply/BAT0/status', 'Charging\n');
  await write(root, '/sys/class/power_supply/AC/type', 'Mains\n');
  await write(root, '/sys/class/power_supply/AC/online', '1\n');
  const result = await power.status();
  assert.equal(result.battery, 57); assert.equal(result.pluggedIn, true);
  assert.equal(result.lidClosed, true); assert.equal(result.idleSeconds, 42);
  assert.equal(calls.length, 0);
});

test('Linux full battery alone does not claim confirmed AC power', async t => {
  const { power, root } = await linuxFixture(t);
  await write(root, '/sys/class/power_supply/BAT0/type', 'Battery');
  await write(root, '/sys/class/power_supply/BAT0/capacity', '100');
  await write(root, '/sys/class/power_supply/BAT0/status', 'Full');
  assert.equal((await power.status()).pluggedIn, null);
});

test('Linux no lid sensor disables active lid sleep rather than claiming support', async t => {
  const { power } = await linuxFixture(t, { lid: null });
  assert.equal((await power.status()).lidClosed, null);
  assert.equal(power.capabilities().lidSleep, false);
  await assert.rejects(power.setLidMode('sleep'), /不支持/);
});

test('Linux actions route to fixed executable arguments', async t => {
  const { power, calls } = await linuxFixture(t);
  await power.sleep(); await power.displayOff(); await power.lock();
  assert.deepEqual(calls, [['systemctl', ['suspend']], ['xset', ['dpms', 'force', 'off']], ['loginctl', ['lock-session']]]);
});

test('Linux sleep lid mode needs sensor but no persistent setting edits', async t => {
  const { power, calls } = await linuxFixture(t);
  assert.equal((await power.setLidMode('sleep')).ok, true);
  assert.equal(power.lidMode, 'sleep');
  await power.shutdown();
  assert.equal(power.lidMode, 'system');
  assert.equal(calls.length, 0);
});

test('Invalid lid mode cannot spawn or mutate anything', async () => {
  const power = new PlatformPower({ platform: 'win32', spawn: () => { throw new Error('spawned'); } });
  await assert.rejects(power.setLidMode('shutdown'), /无效/);
});

test('Windows guard confirms activation and waits for verified restore on shutdown', async t => {
  const root = await fixture(t);
  let argsReceived;
  const power = new PlatformPower({ platform: 'win32', stateDir: root,
    run: async () => ({ stdout: '{"ok":true,"battery":60,"pluggedIn":true}' }),
    spawn: (file, args) => {
      argsReceived = args;
      const child = new EventEmitter(); child.stderr = new PassThrough(); child.unref = () => {};
      const token = args[args.indexOf('-Token') + 1], lease = args[args.indexOf('-Lease') + 1];
      const status = path.join(root, `${token}.status.json`);
      const polling = setInterval(async () => {
        try { await fs.access(lease); }
        catch {
          clearInterval(polling);
          await fs.writeFile(status, JSON.stringify({ token, status: 'restored' }));
          child.emit('exit', 0);
        }
      }, 20);
      t.after(() => clearInterval(polling));
      setTimeout(() => fs.writeFile(status, JSON.stringify({ token, status: 'active' })), 10);
      return child;
    } });
  assert.equal((await power.setLidMode('keep')).ok, true);
  assert.equal(power.lidMode, 'keep');
  assert.equal(argsReceived[argsReceived.indexOf('-Mode') + 1], 'keep');
  await power.shutdown();
  assert.equal(power.guard, null); assert.equal(power.lidMode, 'system');
});

test('Failed guard state emits failure and shutdown still awaits restoration', async t => {
  const root = await fixture(t);
  const lease = path.join(root, 'test.lease');
  const statusFile = path.join(root, 'test.status.json');
  await fs.writeFile(lease, 'test');
  await fs.writeFile(statusFile, '{"token":"test","status":"restored","message":"AC disconnected"}');
  const power = new PlatformPower({ platform: 'win32', stateDir: root,
    run: async () => ({ stdout: '{"ok":true}' }) });
  const failures = [];
  power.on('failure', error => failures.push(error.message));
  power.guard = { token: 'test', lease, statusFile, platform: 'win32' };
  power.lidMode = 'keep';
  await power.status();
  assert.deepEqual(failures, ['AC disconnected']); assert.equal(power.lidMode, 'system');
  await power.shutdown();
  assert.equal(power.guard, null);
});
