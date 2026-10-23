#!/usr/bin/python3
"""Run any local Agent command with a task lease. No conversations or command text are saved."""
import argparse, json, os, pathlib, signal, subprocess, sys, threading, time, uuid

def main():
    parser = argparse.ArgumentParser(description='SleepDock 通用 Agent 任务接入')
    parser.add_argument('--name', default='Agent 任务')
    parser.add_argument('--agent', default=None, help='deepseek/codex/workbuddy/muse/claude/cindy 或自定义App标识')
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command: parser.error('在 -- 后提供要运行的命令')
    directory = pathlib.Path.home() / '.sleepdock/tasks'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    task_id = str(uuid.uuid4()); path = directory / (task_id + '.json')
    task = dict(id=task_id, name=args.name, pid=os.getpid(), createdAt=time.time(), agentID=args.agent)
    stop = threading.Event()
    def write(state='running'):
        task.update(state=state, heartbeatAt=time.time())
        temporary = path.with_suffix('.tmp')
        temporary.write_text(json.dumps(task, ensure_ascii=False)); temporary.chmod(0o600); temporary.replace(path)
    def heartbeat():
        while not stop.wait(3): write()
    write(); worker=threading.Thread(target=heartbeat, daemon=True); worker.start()
    child = None
    was_interrupted = False
    def interrupted(signum, frame):
        nonlocal was_interrupted
        was_interrupted = True
        if child and child.poll() is None:
            child.send_signal(signal.CTRL_BREAK_EVENT if os.name == 'nt' else signum)
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    code = 1
    try:
        child = subprocess.Popen(command, creationflags=subprocess.CREATE_NEW_PROCESS_GROUP if os.name == 'nt' else 0)
        code = child.wait()
    except (OSError, KeyboardInterrupt) as error:
        print(str(error), file=sys.stderr)
    finally:
        stop.set(); worker.join(timeout=5)
        write('complete' if code == 0 and not was_interrupted else 'aborted')
    return code if code >= 0 else 128-code

if __name__ == '__main__': sys.exit(main())
