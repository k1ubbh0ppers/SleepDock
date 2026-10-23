import os
import sys
import pathlib
import shlex
import signal
import subprocess
import tempfile
import threading
import time
import uuid

PROJECT = pathlib.Path(__file__).resolve().parents[1]
SOURCE = (PROJECT/'Resources/lid-watchdog.sh').read_text()
WORK = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else pathlib.Path(tempfile.mkdtemp(prefix='sleepdock-lid-checks-'))
WORK.mkdir(parents=True, exist_ok=True)
UID = os.getuid()
PASSED = []

def wait_for(predicate, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError('timed out')

class Sandbox:
    def __init__(self, name, snapshot_failure=False):
        self.path = pathlib.Path(tempfile.mkdtemp(prefix=name+'-', dir=WORK))
        self.base = self.path/'SleepDock'
        self.value = self.path/'value'
        self.value.write_text('0\n')
        self.log = self.path/'mutations'
        mock = self.path/'pmset-mock'
        mock.write_text('#!/bin/bash\nif [ "$1" = -g ]; then\n'
                        f'printf "SleepDisabled %s\\n" "$(/bin/cat {shlex.quote(str(self.value))})"\n'
                        'else\n'
                        f'printf "%s\\n" "$3" > {shlex.quote(str(self.value))}\n'
                        f'printf "%s\\n" "$3" >> {shlex.quote(str(self.log))}\nfi\n')
        mock.chmod(0o700)
        text = SOURCE.replace("base='/Library/Application Support/com.phecda.SleepDock'", 'base='+shlex.quote(str(self.base)))
        text = text.replace('lease="/tmp/com.phecda.SleepDock-lid-', 'lease="'+str(self.path)+'/lease-')
        text = text.replace('/usr/bin/pmset', shlex.quote(str(mock)))
        text = text.replace('$(/usr/bin/id -u)" = 0', f'$(/usr/bin/id -u)" = {UID}')
        for item in ['directory', 'state', 'mutex', 'lock']:
            text = text.replace(f'$(/usr/bin/stat -f %u "${item}")" = 0',
                                f'$(/usr/bin/stat -f %u "${item}")" = {UID}')
        text = text.replace('/usr/sbin/chown root:wheel', '/usr/bin/true')
        if snapshot_failure:
            text = text.replace('temporary="$root/state.$$"', 'temporary="$root/missing/state.$$"')
        assert '/usr/bin/pmset' not in text, 'real power command must be fully replaced'
        assert "base='/Library/Application Support/com.phecda.SleepDock'" not in text, 'real state path must be fully replaced'
        self.script = self.path/'guard.sh'
        self.script.write_text(text)
        self.app = subprocess.Popen(['/bin/sleep', '120'])
        self.guards = []
        self.leases = set()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.heartbeat, daemon=True)
        self.thread.start()

    def heartbeat(self):
        while not self.stop.wait(0.2):
            for lease in list(self.leases):
                try:
                    os.utime(lease, None)
                except FileNotFoundError:
                    pass

    def new(self, lease=True, symlink=False):
        token = str(uuid.uuid4())
        lease_path = self.path/f'lease-{UID}-{token}.lease'
        if lease:
            if symlink:
                lease_path.symlink_to(self.value)
            else:
                lease_path.write_text(token)
            self.leases.add(lease_path)
        process = subprocess.Popen(['/bin/bash', str(self.script), str(self.app.pid), str(UID), token], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.guards.append(process)
        return token, lease_path, process

    def state(self):
        try:
            return dict(line.split('=', 1) for line in (self.base/'LidGuard/state').read_text().splitlines())
        except (FileNotFoundError, ValueError):
            return {}

    def active(self, token):
        state = self.state()
        return state.get('token') == token and state.get('status') == 'active'

    def remove(self, lease):
        self.leases.discard(lease)
        lease.unlink(missing_ok=True)

    def mutations(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def finish(self):
        for lease in list(self.leases):
            self.remove(lease)
        for guard in self.guards:
            try:
                guard.wait(timeout=6)
            except subprocess.TimeoutExpired:
                guard.terminate()
                guard.wait(timeout=4)
        self.stop.set()
        self.thread.join()
        self.app.terminate()
        self.app.wait()

def test(name, function, snapshot_failure=False):
    sandbox = Sandbox(name, snapshot_failure)
    try:
        function(sandbox)
        PASSED.append(name)
    finally:
        sandbox.finish()

def normal(s):
    token, lease, guard = s.new()
    wait_for(lambda: s.active(token))
    assert s.state()['original'] == '0'
    s.remove(lease)
    assert guard.wait(timeout=5) == 0
    assert s.value.read_text().strip() == '0'
    assert s.state()['status'] == 'restored'
    assert s.mutations() == ['1', '0']

def concurrent(s):
    ta, la, ga = s.new()
    wait_for(lambda: s.active(ta))
    tb, lb, gb = s.new()
    time.sleep(0.4)
    assert s.active(ta) and s.mutations() == ['1']
    s.remove(la)
    wait_for(lambda: s.active(tb))
    assert s.state()['original'] == '0'
    assert s.mutations() == ['1', '0', '1']
    s.remove(lb)
    assert gb.wait(timeout=5) == 0
    assert s.mutations() == ['1', '0', '1', '0']

def killed(s):
    ta, la, ga = s.new()
    wait_for(lambda: s.active(ta))
    ga.kill()
    ga.wait()
    s.remove(la)
    assert s.value.read_text().strip() == '1'
    tb, lb, gb = s.new()
    wait_for(lambda: s.active(tb))
    assert s.state()['original'] == '0'
    assert s.mutations() == ['1', '0', '1']
    s.remove(lb)
    assert gb.wait(timeout=5) == 0
    assert s.value.read_text().strip() == '0'

def failed_snapshot(s):
    _, _, guard = s.new()
    assert guard.wait(timeout=5) == 74
    assert s.mutations() == [] and s.value.read_text().strip() == '0'

def cancelled(s):
    _, _, guard = s.new(lease=False)
    assert guard.wait(timeout=5) == 69
    assert s.mutations() == []

def symlink(s):
    _, _, guard = s.new(symlink=True)
    assert guard.wait(timeout=5) == 69
    assert s.mutations() == []

def corrupt(s):
    root = s.base/'LidGuard'
    root.mkdir(parents=True)
    (root/'state').write_text('original=0\nstatus=invalid\n')
    _, _, guard = s.new()
    assert guard.wait(timeout=5) == 78
    assert s.mutations() == []

test('normal_restore', normal)
test('serialized_reenable', concurrent)
test('hardkill_recovery', killed)
test('snapshot_failure_no_mutation', failed_snapshot, snapshot_failure=True)
test('cancelled_before_authorization', cancelled)
test('symlink_lease_rejected', symlink)
test('corrupt_record_rejected', corrupt)

# Check the exact two-layer quoting used for the in-memory script snapshot.
source = 'printf \'%s\' "$1"\n'
argument = "quote' slash\\ newline\n结束"
quote = lambda text: "'"+text.replace("'", "'\\''")+"'"
command = '/bin/bash -c '+quote(source)+' sleepdock '+quote(argument)
apple = 'do shell script "'+command.replace('\\', '\\\\').replace('"', '\\"')+'"'
result = subprocess.run(['/usr/bin/osascript', '-e', apple], text=True, capture_output=True)
assert result.returncode == 0, result.stderr
assert result.stdout.rstrip('\n') == argument
PASSED.append('snapshot_shell_quoting')
print('PASS '+str(len(PASSED))+': '+', '.join(PASSED))
