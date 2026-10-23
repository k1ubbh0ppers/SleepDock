'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { AgentMonitor, discoverApps, CATALOG } = require('../src/agents.cjs');
const all = CATALOG.map(app => app.id);
const emptyRun = async () => ({ stdout: '' });
const now = Date.now();
const iso = time => new Date(time).toISOString();
function fixture(t, options = {}) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'sleepdock-agents-'));
  t.after(() => fs.rmSync(home, { recursive: true, force: true }));
  const root = path.join(home, '.codex/sessions');
  const leaseDir = path.join(home, '.sleepdock/tasks');
  fs.mkdirSync(root, { recursive: true }); fs.mkdirSync(leaseDir, { recursive: true });
  const monitor = new AgentMonitor({ home, platform: 'linux', run: emptyRun, env: { PATH: '' }, ...options });
  const file = (name = 'a') => path.join(root, name + '.jsonl');
  const append = (target, object, newline = true) => fs.appendFileSync(target, JSON.stringify(object) + (newline ? '\n' : ''));
  const meta = (target, created = now - 10000, extra = {}) => append(target, { type: 'session_meta', payload: { id: path.basename(target), timestamp: iso(created), ...extra } });
  const event = (target, type, id, at = now, started = now, newline = true) => append(target, { type: 'event_msg', timestamp: iso(at), payload: { type, turn_id: id, started_at: started / 1000 } }, newline);
  const lease = (id, extra = {}, filename = id) => fs.writeFileSync(path.join(leaseDir, filename + '.json'), JSON.stringify({ id, name: 'Test task', agentID: 'claude', pid: process.pid, createdAt: now / 1000, heartbeatAt: now / 1000, state: 'running', ...extra }));
  return { home, root, leaseDir, monitor, file, append, meta, event, lease };
}

test('six default agents retain stable selection identifiers', () => {
  assert.deepEqual(all, ['deepseek', 'codex', 'workbuddy', 'muse', 'claude', 'cindy']);
});

test('concurrent Codex completions retain exact task identity and emit once', async t => {
  const f = fixture(t); const a = f.file('a'), b = f.file('b');
  f.meta(a); f.meta(b); f.event(a, 'task_started', 'A'); f.event(b, 'task_started', 'B');
  const initial = await f.monitor.poll(all, [], now);
  assert.equal(initial.tasks.length, 2); assert.deepEqual(initial.completedTaskIDs, []);
  f.event(a, 'task_complete', 'A', now + 1000);
  const one = await f.monitor.poll(all, [], now + 1000);
  assert.equal(one.tasks.length, 1); assert.deepEqual(one.completedTaskIDs, ['A']);
  f.event(b, 'task_complete', 'B', now + 2000);
  const two = await f.monitor.poll(all, [], now + 2000);
  assert.equal(two.tasks.length, 0); assert.deepEqual(two.completedTaskIDs, ['B']);
  assert.deepEqual((await f.monitor.poll(all, [], now + 3000)).completedTaskIDs, []);
});

test('startup completed history never arms auto sleep', async t => {
  const f = fixture(t), file = f.file(); f.meta(file);
  f.event(file, 'task_started', 'old', now - 5000, now - 5000);
  f.event(file, 'task_complete', 'old', now - 2000, now - 5000);
  const result = await f.monitor.poll(all, [], now);
  assert.deepEqual(result.tasks, []); assert.deepEqual(result.completedTaskIDs, []); assert.deepEqual(result.interruptedSources, []);
});

test('short abort between polls survives an otherwise successful empty snapshot', async t => {
  const f = fixture(t), file = f.file(); f.meta(file); f.event(file, 'task_started', 'A');
  await f.monitor.poll(all, [], now);
  f.event(file, 'task_started', 'B', now + 1000, now + 1000);
  f.event(file, 'turn_aborted', 'B', now + 2000, now + 1000);
  f.event(file, 'task_complete', 'A', now + 3000);
  const result = await f.monitor.poll(all, [], now + 4000);
  assert.deepEqual(result.tasks, []); assert.deepEqual(result.completedTaskIDs, ['A']); assert.deepEqual(result.interruptedSources, ['codex']);
  assert.deepEqual((await f.monitor.poll(all, [], now + 5000)).interruptedSources, []);
});

test('forked parent replay cannot cancel parent or poison child completion', async t => {
  const f = fixture(t), parent = f.file('parent'), child = f.file('child');
  f.meta(parent); f.event(parent, 'task_started', 'parent'); await f.monitor.poll(all, [], now);
  f.meta(child, now, { subagent_history_start_ordinal: 4 });
  f.meta(child, now - 10000);
  f.event(child, 'task_started', 'parent'); f.event(child, 'turn_aborted', 'parent');
  f.event(child, 'task_started', 'child', now + 1000, now + 1000);
  assert.equal((await f.monitor.poll(all, [], now + 1000)).tasks.length, 2);
  f.event(parent, 'task_complete', 'parent', now + 2000);
  f.event(child, 'task_complete', 'child', now + 2000, now + 1000);
  const result = await f.monitor.poll(all, [], now + 2000);
  assert.equal(result.tasks.length, 0); assert.deepEqual(result.interruptedSources, []);
  assert.deepEqual(new Set(result.completedTaskIDs), new Set(['parent', 'child']));
});

test('replayed starts older than child identity are ignored without ordinal metadata', async t => {
  const f = fixture(t), file = f.file(); f.meta(file, now);
  f.event(file, 'task_started', 'replay', now, now - 5000);
  f.event(file, 'turn_aborted', 'replay', now, now - 5000);
  f.event(file, 'task_started', 'actual');
  assert.deepEqual((await f.monitor.poll(all, [], now)).tasks.map(task => task.id), ['actual']);
});

test('partial JSONL waits for newline; UTF8 chunks are not decoded prematurely', async t => {
  const f = fixture(t), file = f.file(); f.meta(file); f.event(file, 'task_started', 'A');
  await f.monitor.poll(all, [], now); f.event(file, 'task_complete', 'A', now + 1000, now, false);
  assert.equal((await f.monitor.poll(all, [], now + 1000)).tasks.length, 1);
  fs.appendFileSync(file, '\n');
  assert.deepEqual((await f.monitor.poll(all, [], now + 2000)).completedTaskIDs, ['A']);
});

test('truncated active log is uncertain/interrupted, never successful', async t => {
  const f = fixture(t), file = f.file(); f.meta(file); f.event(file, 'task_started', 'A');
  await f.monitor.poll(all, [], now); fs.writeFileSync(file, '');
  const result = await f.monitor.poll(all, [], now + 1000);
  assert.deepEqual(result.uncertainSources, ['codex']); assert.deepEqual(result.interruptedSources, ['codex']); assert.deepEqual(result.completedTaskIDs, []);
});

test('lost active log retains task and uncertainty instead of claiming completion', async t => {
  const f = fixture(t), file = f.file(); f.meta(file); f.event(file, 'task_started', 'A');
  await f.monitor.poll(all, [], now); fs.unlinkSync(file);
  const result = await f.monitor.poll(all, [], now + 1000);
  assert.equal(result.tasks.length, 1); assert.deepEqual(result.uncertainSources, ['codex']); assert.deepEqual(result.completedTaskIDs, []);
});

test('missing turn id and malformed lifecycle records preserve uncertainty', async t => {
  const f = fixture(t), file = f.file(); f.meta(file);
  f.append(file, { type: 'event_msg', payload: { type: 'task_started' } });
  assert.deepEqual((await f.monitor.poll(all, [], now)).uncertainSources, ['codex']);
});

test('terminal without event time cannot silently poison a successful batch', async t => {
  const f = fixture(t), file = f.file(); f.meta(file); f.event(file, 'task_started', 'A');
  await f.monitor.poll(all, [], now);
  f.event(file, 'task_started', 'B', now + 1000, now + 1000);
  f.append(file, { type: 'event_msg', payload: { type: 'task_complete', turn_id: 'B' } });
  f.event(file, 'task_complete', 'A', now + 2000);
  const result = await f.monitor.poll(all, [], now + 3000);
  assert.deepEqual(result.uncertainSources, ['codex']); assert.equal(result.tasks[0].id, 'B');
});

test('selected sources filter active tasks, completions and uncertainty', async t => {
  const f = fixture(t), file = f.file(); f.meta(file); f.event(file, 'task_started', 'A'); f.lease('lease');
  const initial = await f.monitor.poll(['claude'], [], now);
  assert.deepEqual(initial.tasks.map(task => task.source), ['claude']);
  f.event(file, 'task_complete', 'A', now + 1000);
  assert.deepEqual((await f.monitor.poll(['claude'], [], now + 1000)).completedTaskIDs, []);
  fs.appendFileSync(file, 'invalid\n');
  assert.deepEqual((await f.monitor.poll(['claude'], [], now + 2000)).uncertainSources, []);
});

test('fresh live lease protects then emits normal completion with exact lease id', async t => {
  const f = fixture(t); f.lease('task', {}, 'different-filename');
  assert.deepEqual((await f.monitor.poll(['claude'], [], now)).tasks.map(task => task.id), ['lease:task']);
  f.lease('task', { state: 'complete', heartbeatAt: (now + 1000) / 1000 }, 'different-filename');
  assert.deepEqual((await f.monitor.poll(['claude'], [], now + 1000)).completedTaskIDs, ['lease:task']);
  assert.deepEqual((await f.monitor.poll(['claude'], [], now + 2000)).completedTaskIDs, []);
});

test('expired lease is uncertain once; late success cannot manufacture completion', async t => {
  const f = fixture(t); f.lease('task'); await f.monitor.poll(all, [], now);
  const expired = await f.monitor.poll(all, [], now + 21000);
  assert.equal(expired.tasks.length, 0); assert.deepEqual(expired.uncertainSources, ['claude']); assert.deepEqual(expired.interruptedSources, ['claude']);
  assert.deepEqual((await f.monitor.poll(all, [], now + 22000)).uncertainSources, []);
  f.lease('task', { state: 'complete', heartbeatAt: (now + 23000) / 1000 });
  assert.deepEqual((await f.monitor.poll(all, [], now + 23000)).completedTaskIDs, []);
});

test('terminal source cannot switch a task into a different selected source', async t => {
  const f = fixture(t); f.lease('task'); await f.monitor.poll(['muse'], [], now);
  f.lease('task', { state: 'complete', agentID: 'muse', heartbeatAt: (now + 1000) / 1000 });
  assert.deepEqual((await f.monitor.poll(['muse'], [], now + 1000)).completedTaskIDs, []);
});

test('short failed lease between polls emits source once', async t => {
  const f = fixture(t); await f.monitor.poll(all, [], now);
  f.lease('short', { state: 'aborted', createdAt: (now + 1000) / 1000, heartbeatAt: (now + 2000) / 1000 });
  assert.deepEqual((await f.monitor.poll(all, [], now + 3000)).interruptedSources, ['claude']);
  assert.deepEqual((await f.monitor.poll(all, [], now + 4000)).interruptedSources, []);
});

test('deleted lease interrupts batch with source preserved', async t => {
  const f = fixture(t); f.lease('task'); await f.monitor.poll(all, [], now);
  fs.unlinkSync(path.join(f.leaseDir, 'task.json'));
  const result = await f.monitor.poll(all, [], now + 1000);
  assert.deepEqual(result.interruptedSources, ['claude']); assert.deepEqual(result.uncertainSources, ['claude']); assert.deepEqual(result.completedTaskIDs, []);
});

test('malformed lease conservatively marks global unknown', async t => {
  const f = fixture(t); fs.writeFileSync(path.join(f.leaseDir, 'bad.json'), '{');
  assert.deepEqual((await f.monitor.poll(all, [], now)).uncertainSources, ['*']);
});

test('Windows CSV image names match exact apps, not generic node/electron', async t => {
  const run = async (file, args) => {
    if (file === 'powershell.exe') return { stdout: JSON.stringify([{ Name: 'node.exe', ExecutablePath: 'C:\\node\\node.exe', CommandLine: 'node.exe C:\\unrelated\\cli.js --prompt claude' }]) };
    assert.equal(file, 'tasklist.exe'); assert.deepEqual(args, ['/FO', 'CSV', '/NH']);
    return { stdout: '"WorkBuddy.exe","11","Console","1","10 K"\r\n"node.exe","12","Console","1","10 K"\r\n"Cindy.exe","13","Console","1","10 K"\r\n' };
  };
  const f = fixture(t, { platform: 'win32', run });
  const result = await f.monitor.poll(all, [], now);
  assert.deepEqual(result.tasks.map(task => task.source), ['workbuddy', 'cindy']);
  assert.equal(result.apps.find(app => app.id === 'claude').running, false);
  assert.equal(result.apps.find(app => app.id === 'cindy').installed, true);
});

test('known npm CLI entrypoints protect on both Windows and Linux without prompt matches', async t => {
  const command = '"C:\\Program Files\\nodejs\\node.exe" "C:\\TestApps\\npm\\node_modules\\@anthropic-ai\\claude-code\\cli.js" --prompt "codex muse"';
  const f = fixture(t, { platform: 'win32', run: async file => ({ stdout: file === 'tasklist.exe' ? '"node.exe","123","Console","1","1 K"' : JSON.stringify({ Name: 'node.exe', CommandLine: command }) }) });
  assert.deepEqual((await f.monitor.poll(all, [], now)).tasks.map(task => task.source), ['claude']);
  const linux = fixture(t, { run: async () => ({ stdout: 'node /usr/bin/node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js -p hello\nnode /usr/bin/node /tmp/unrelated.js claude\n' }) });
  assert.deepEqual((await linux.monitor.poll(all, [], now)).tasks.map(task => task.source), ['claude']);
});

test('unreadable node commandline preserves CLI source uncertainty', async t => {
  const f = fixture(t, { platform: 'win32', run: async file => {
    if (file === 'tasklist.exe') return { stdout: '"node.exe","123","Console","1","1 K"' };
    throw new Error('CIM access denied');
  } });
  assert.deepEqual((await f.monitor.poll(['claude'], [], now)).uncertainSources, ['claude']);
});

test('Linux process exit releases app protection but never emits completion', async t => {
  let output = 'muse /opt/muse/muse\n';
  const f = fixture(t, { run: async () => ({ stdout: output }) });
  assert.deepEqual((await f.monitor.poll(all, [], now)).tasks.map(task => task.id), ['app:muse']);
  output = '';
  const result = await f.monitor.poll(all, [], now + 1000);
  assert.deepEqual(result.tasks, []); assert.deepEqual(result.completedTaskIDs, []);
});

test('process lookup failures block only selected sources', async t => {
  const f = fixture(t, { run: async () => { throw new Error('permission denied'); } });
  const result = await f.monitor.poll(['muse'], [], now);
  assert.deepEqual(result.uncertainSources, ['muse']); assert.deepEqual(result.completedTaskIDs, []);
});

test('custom executable path discovers installed/running app with persistent id', async t => {
  const f = fixture(t, { run: async () => ({ stdout: 'custom-agent /opt/custom-agent\n' }) });
  const executable = path.join(f.home, 'custom-agent'); fs.writeFileSync(executable, '');
  const custom = [{ id: 'custom-1', name: 'My Agent', path: executable }];
  const result = await f.monitor.poll(['custom-1'], custom, now);
  assert.deepEqual(result.tasks.map(task => task.source), ['custom-1']);
  assert.equal(result.apps.at(-1).installed, true); assert.equal(result.apps.at(-1).path, executable);
});

test('desktop entry reads executable without running desktop command', async t => {
  const f = fixture(t, { run: async () => ({ stdout: 'agent-bin /opt/agent-bin --serve\n' }) });
  const desktop = path.join(f.home, 'my-agent.desktop');
  fs.writeFileSync(desktop, '[Desktop Entry]\nName=My Agent\nExec=env MODE=agent /opt/agent-bin %U\n');
  const apps = await discoverApps({ home: f.home, platform: 'linux', run: f.monitor.run, env: { PATH: '' }, customApps: [{ id: 'mine', name: 'My Agent', path: desktop }] });
  assert.equal(apps.at(-1).running, true); assert.equal(apps.at(-1).installed, true);
});

test('CLI executable discovery checks user-local bin', async t => {
  const f = fixture(t); const bin = path.join(f.home, '.local/bin'); fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(bin, 'claude'), '');
  const apps = await discoverApps({ home: f.home, platform: 'linux', run: emptyRun, env: { PATH: '' } });
  assert.equal(apps.find(app => app.id === 'claude').installed, true);
});

test('resumed old-directory conversation is discovered by recent modification', async t => {
  const f = fixture(t); const old = path.join(f.root, '2020/01/01'); fs.mkdirSync(old, { recursive: true });
  const file = path.join(old, 'resumed.jsonl'); f.meta(file, now - 10000000); f.event(file, 'task_started', 'resumed');
  assert.equal((await f.monitor.poll(['codex'], [], now)).tasks[0].id, 'resumed');
});

test('stale unfinished task is retained with uncertainty', async t => {
  const f = fixture(t), file = f.file(); f.meta(file, now - 7000000); f.event(file, 'task_started', 'stale', now - 6000000, now - 6000000);
  fs.utimesSync(file, (now - 2000000) / 1000, (now - 2000000) / 1000);
  const result = await f.monitor.poll(['codex'], [], now);
  assert.equal(result.tasks.length, 1); assert.deepEqual(result.uncertainSources, ['codex']);
});
