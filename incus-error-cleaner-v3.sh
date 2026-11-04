#!/usr/bin/env bash
# Incus selective ERROR cleaner v3.0
# Detects stalled instance operations before issuing any new destructive requests.
set -euo pipefail
command -v python3 >/dev/null 2>&1 || { echo 'python3 is required' >&2; exit 2; }
exec python3 - "$@" <<'PY'
import argparse
import datetime as datetime
import fcntl
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import time
from urllib.parse import urlsplit, unquote, parse_qs

parser = argparse.ArgumentParser(description='Remove Incus ERROR containers only, without repeatedly stacking stuck operations.')
parser.add_argument('--dry-run', action='store_true', help='Inspection only; no deletion, daemon restart, or cancellation')
parser.add_argument('--recycle-daemon', action='store_true', help='OPT IN to one checked systemctl restart incus.service to clear old in-memory locks')
parser.add_argument('--stale-seconds', type=int, default=120, help='Minimum age for suspect lifecycle operation (>=120)')
parser.add_argument('--allow-stale-exec', action='store_true', help='OPT IN: allow recycling while OTHER instances have Executing command operations older than 1 hour; live exec sessions may disconnect')
args = parser.parse_args()
if args.stale_seconds < 120:
    parser.error('For safety, --stale-seconds must be >=120')
if os.geteuid() != 0:
    sys.exit('Run as root')

lock_handle = open('/run/lock/incus-error-cleaner.lock', 'a+')
try:
    fcntl.flock(lock_handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit('Another cleaner is running')

root = pathlib.Path('/var/log/incus-error-cleaner')
root.mkdir(parents=True, exist_ok=True)
logdir = root / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-v3')
logdir.mkdir(mode=0o700)
logpath = logdir / 'run.log'
summary = {'deleted': [], 'deferred': [], 'unresolved': [], 'running_dropped': [], 'recycled': False}

def log(message):
    line = '[' + datetime.datetime.now().strftime('%H:%M:%S') + '] ' + message
    print(line, flush=True)
    with open(logpath, 'a') as fp:
        fp.write(line + '\n')

def save(name, value):
    destination = logdir / name
    destination.write_text(value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, indent=2))
    destination.chmod(0o600)

def run(command, seconds=20):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               stdin=subprocess.DEVNULL, start_new_session=True,
                               text=True, errors='replace')
    try:
        out, err = process.communicate(timeout=seconds)
        return process.returncode, out, err, False
    except subprocess.TimeoutExpired:
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        try: out, err = process.communicate(timeout=3)
        except subprocess.TimeoutExpired: out, err = '', 'client did not exit'
        return 124, out, err, True

def incus(*argv, project=None, timeout=20):
    command = ['incus', '--force-local']
    if project is not None:
        command.extend(['--project', project])
    command.extend(argv)
    return run(command, timeout)

def parse_json(result, what):
    rc, out, err, timed = result
    if timed or rc != 0:
        raise RuntimeError(f'{what}: rc={rc}, timeout={timed}, error={(err or out).strip()[:350]}')
    try: return json.loads(out)
    except json.JSONDecodeError as exc: raise RuntimeError(f'{what}: invalid JSON: {exc}')

def instances():
    response = parse_json(incus('list', '--all-projects', '--format=json', timeout=30), 'list instances')
    if not isinstance(response, list): raise RuntimeError('instance list is not an array')
    return response

def listing(project, name):
    response = parse_json(incus('list', '--format=json', project=project, timeout=20), 'list project instances')
    matches = [i for i in response if i.get('name') == name]
    return matches[0] if matches else None

def protected(instance):
    for config_name in ('config', 'expanded_config'):
        config = instance.get(config_name) or {}
        if str(config.get('security.protection.delete', '')).lower() in ('true', '1'):
            return True
    return False

def identity(instance):
    return (instance.get('project') or 'default', instance.get('name'))

def active(op):
    try: return 100 <= int(op.get('status_code', -1)) < 200
    except (TypeError, ValueError):
        return str(op.get('status', '')).lower() in ('running', 'pending', 'created', 'canceling')

def op_age(op):
    try:
        value = datetime.datetime.fromisoformat(op.get('created_at', '').replace('Z', '+00:00'))
        if not value.tzinfo: return 0.0
        return max(0.0, (datetime.datetime.now(datetime.timezone.utc) - value).total_seconds())
    except (TypeError, ValueError, AttributeError):
        return 0.0

def matches(op, project, name):
    for res in ((op.get('resources') or {}).get('instances') or []):
        if not isinstance(res, str): continue
        uri = urlsplit(res)
        if unquote(uri.path) != '/1.0/instances/' + name: continue
        projs = parse_qs(uri.query).get('project', [])
        if projs and projs[0] != project: continue
        # If API omits project in resource, this matching is only unambiguous
        # when the current operation list is already scoped to the project.
        return True
    return False

def project_ops(project, name):
    response = parse_json(incus('operation', 'list', '--format=json', project=project, timeout=20), 'list operations')
    if not isinstance(response, list): raise RuntimeError('operation list is not an array')
    return [op for op in response if matches(op, project, name) and active(op)]

def lifecycle(op):
    return bool(re.search(r'\b(stop|stopping|start|starting|restart|restarting|delete|deleting|remove|removing)\b',
                          str(op.get('description', '')).lower()))

def target_pids(name):
    pids = []
    segment = 'lxc.payload.' + name
    for entry in pathlib.Path('/proc').iterdir():
        if not entry.name.isdigit(): continue
        try:
            cg = (entry / 'cgroup').read_text()
            if not any(segment in line.split(':', 2)[-1].split('/') for line in cg.splitlines()):
                continue
            status = (entry / 'status').read_text()
            state = re.search(r'^State:\s+(\S+)', status, re.MULTILINE)
            pids.append({'pid': int(entry.name), 'state': state.group(1) if state else '?'})
        except (OSError, ProcessLookupError):
            continue
    return pids

def fresh_or_other(ops):
    return any(op_age(op) < args.stale_seconds or not lifecycle(op) for op in ops)

def must_be_error(project, name):
    state = listing(project, name)
    if state is None: return None
    if state.get('status', '').upper() != 'ERROR' or state.get('type', '').lower() != 'container' or protected(state):
        return False
    return state

def delete_once(project, name, force=True):
    state = listing(project, name)
    if state is None:
        return True
    if protected(state) or state.get('type', '').lower() != 'container':
        log(f'  Refusing removal: protection/type changed for {project}/{name}')
        return False
    status = str(state.get('status', '')).upper()
    if status not in ('ERROR', 'STOPPED'):
        log(f'  Refusing removal: status changed to {status} for {project}/{name}')
        return False
    command = ['delete', name]
    if force and status == 'ERROR': command.append('--force')
    log('  Deleting (once): ' + ' '.join(command))
    result = incus(*command, project=project, timeout=45)
    save(f'delete-{name}.txt', {'rc': result[0], 'stdout': result[1], 'stderr': result[2], 'timed_out': result[3]})
    try:
        gone = listing(project, name) is None
    except Exception as exc:
        log(f'  Unable to verify deletion: {exc}')
        return False
    if gone:
        log('  VERIFIED DELETED: ' + project + '/' + name)
    else:
        log(f'  Still present. delete rc={result[0]}, timeout={result[3]}: {result[2].strip()[:200]}')
    return gone

def systemctl_prop(prop):
    result = run(['systemctl', 'show', 'incus.service', '-p', prop, '--value'], 10)
    if result[0] or result[3]: raise RuntimeError(f'systemctl {prop}: {result[2].strip()}')
    return result[1].strip()

def daemon_preflight(targets):
    if systemctl_prop('ActiveState') != 'active': raise RuntimeError('incus.service is not active')
    if systemctl_prop('KillMode') != 'process': raise RuntimeError('KillMode is not process; restart could terminate payload')
    if systemctl_prop('ExecStop'): raise RuntimeError('ExecStop is customized; refusal to restart')
    job = systemctl_prop('Job')
    if job and job not in ('0', '0/', 'none', 'n/a'):
        raise RuntimeError('systemd job already active: ' + job)
    server = parse_json(incus('query', '/1.0', timeout=20), 'server environment')
    env = server.get('metadata', {}).get('environment', {})
    if str(env.get('server_clustered', False)).lower() in ('true', '1'):
        raise RuntimeError('Incus cluster detected; requires cluster maintenance process')
    ops = parse_json(incus('operation', 'list', '--all-projects', '--format=json', timeout=20), 'all operations')
    if not isinstance(ops, list): raise RuntimeError('all operation response is not an array')
    save('operations-before-recycle.json', ops)
    unrelated_exec = []
    for op in ops:
        if not active(op):
            continue
        op_id = str(op.get('id', '?'))
        descr = str(op.get('description', 'unknown'))
        age = op_age(op)
        res = (op.get('resources') or {}).get('instances') or []
        detail = f'id={op_id}, description={descr}, age={age:.0f}s, instances={res}, may_cancel={op.get("may_cancel")}'
        if any(matches(op, project, name) for project, name in targets):
            if age < args.stale_seconds:
                raise RuntimeError('Target operation too new: ' + detail)
            if not lifecycle(op):
                raise RuntimeError('Target has active non-lifecycle operation: ' + detail)
            continue
        log('  Other active operation: ' + detail)
        if (args.allow_stale_exec and descr.strip().lower() == 'executing command'
                and age >= 3600 and isinstance(res, list) and len(res) == 1):
            # Stale age DOES NOT prove a command is dead; explicit opt-in acknowledges
            # the possibility of disconnecting an intentionally long-running exec.
            unrelated_exec.append(detail)
            continue
        if descr.strip().lower() == 'executing command':
            raise RuntimeError('Unrelated exec operation blocks recycling. Run with --allow-stale-exec ONLY if it is expendable and older than 1 hour: ' + detail)
        raise RuntimeError('Unrelated active operation blocks recycling: ' + detail)
    if unrelated_exec:
        log(f'  WARNING: --allow-stale-exec permits recycle with {len(unrelated_exec)} unrelated exec operation(s); exec sessions may be interrupted')
    before = instances()
    # Global operation resources sometimes omit ?project=. When a target name
    # occurs in multiple projects, global matching is ambiguous: fail closed.
    for target_project, target_name in targets:
        occurrences = [identity(x) for x in before if x.get('name') == target_name]
        if len(occurrences) != 1:
            raise RuntimeError('Ambiguous instance name across projects: ' + target_name)
    running = {identity(i) for i in before if i.get('status', '').upper() == 'RUNNING'}
    save('instances-before-recycle.json', before)
    log(f'  Preflight OK: {len(running)} RUNNING instances will be checked afterward; {len(ops)} operations listed')
    return running

def daemon_recycle(targets):
    log('=== Checked daemon recycle ===')
    try:
        running = daemon_preflight(targets)
    except Exception as exc:
        log('  RECYCLE BLOCKED: ' + str(exc))
        return False
    if args.dry_run:
        log('  DRY-RUN: would restart incus.service')
        return False
    log('  Restarting incus.service. Stuck operations can delay graceful exit.')
    # systemctl controls only the service. Its KillMode=process and no ExecStop were verified.
    outcome = run(['systemctl', 'restart', 'incus.service'], seconds=720)
    save('systemctl-restart.txt', {'rc': outcome[0], 'stdout': outcome[1], 'stderr': outcome[2], 'timed_out': outcome[3]})
    if outcome[0] != 0 or outcome[3]:
        log('  RESTART NOT CONFIRMED. systemd job may still be running: stop, inspect journal/systemctl')
        return False
    ready = incus('admin', 'waitready', '--timeout', '120', timeout=135)
    if ready[0] or ready[3]:
        log('  Incus API not ready after restart; stop without deleting anything')
        return False
    try:
        after = instances()
    except Exception as exc:
        log('  Cannot list instances after restart: ' + str(exc))
        return False
    save('instances-after-recycle.json', after)
    current_running = {identity(i) for i in after if i.get('status', '').upper() == 'RUNNING'}
    dropped = sorted(running - current_running)
    if dropped:
        summary['running_dropped'] = [f'{p}/{n}' for p, n in dropped]
        log('  STOP: Previously RUNNING instances changed state: ' + ', '.join(summary['running_dropped']))
        return False
    summary['recycled'] = True
    log(f'  Recycle verified: all {len(running)} previously RUNNING instances still RUNNING')
    return True

log('Mode=' + ('DRY-RUN' if args.dry_run else 'DELETE') + '; recycle_daemon=' + str(args.recycle_daemon) + '; allow_stale_exec=' + str(args.allow_stale_exec) + '; logs=' + str(logdir))
try:
    before = instances()
    save('instances-before.json', before)
    targets = [i for i in before if i.get('status', '').upper() == 'ERROR'
               and i.get('type', '').lower() == 'container' and not protected(i)]
    log(f'Found {len(before)} instances; {len(targets)} ERROR containers eligible')
    recycle_targets = []
    for index, obj in enumerate(targets, 1):
        project, name = identity(obj)
        label = project + '/' + name
        log(f'=== [{index}/{len(targets)}] {label} ===')
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,62}', name):
            log('  DEFERRED: Invalid/unsupported container name')
            summary['deferred'].append(label)
            continue
        check = must_be_error(project, name)
        if check is None:
            log('  Already absent')
            continue
        if check is False:
            log('  DEFERRED: No longer an unprotected ERROR container')
            summary['deferred'].append(label)
            continue
        ops = project_ops(project, name)
        procs = target_pids(name)
        save('diagnostic-' + name + '.json', {'operations': ops, 'processes': procs})
        for op in ops:
            log(f'  Operation: {op.get("description", "?")}, id={op.get("id", "?")}, age={op_age(op):.0f}s, may_cancel={op.get("may_cancel")}')
        if procs:
            log('  Payload processes: ' + ', '.join(str(p['pid']) + '(' + p['state'] + ')' for p in procs[:20]))
        if any(p['state'] == 'D' for p in procs):
            log('  DEFERRED: D-state container process present; SIGKILL/restart may not resolve kernel I/O')
            summary['deferred'].append(label)
            continue
        if ops:
            if fresh_or_other(ops):
                log('  DEFERRED: recent or non-lifecycle operations; no new delete request issued')
                summary['deferred'].append(label)
                continue
            log('  Old lifecycle operation(s) still running; will NOT issue another delete yet')
            if args.recycle_daemon:
                recycle_targets.append((project, name))
            else:
                summary['unresolved'].append(label)
                log('  Run with --recycle-daemon to attempt checked service recycle')
            continue
        if args.dry_run:
            log('  DRY-RUN: no active operations; would attempt single forced delete')
            continue
        if delete_once(project, name):
            summary['deleted'].append(label)
        else:
            summary['unresolved'].append(label)
            log('  No further operations will be sent in this execution')

    if recycle_targets:
        if args.dry_run and not args.recycle_daemon:
            log('DRY-RUN: old operations detected; use --dry-run --recycle-daemon to inspect restart preflight')
        elif daemon_recycle(recycle_targets):
            for project, name in recycle_targets:
                label = project + '/' + name
                try:
                    if delete_once(project, name): summary['deleted'].append(label)
                    else: summary['unresolved'].append(label)
                except Exception as exc:
                    log('  Post-recycle delete error: ' + str(exc))
                    summary['unresolved'].append(label)
        else:
            summary['unresolved'].extend(project + '/' + name for project, name in recycle_targets)

except Exception as exc:
    log('FATAL: ' + str(exc))
    summary['unresolved'].append('script-aborted')
finally:
    try: save('instances-after.json', instances())
    except Exception as exc: log('WARNING: final list failed: ' + str(exc))
    save('summary.json', summary)
    log('FINAL: deleted=' + str(len(summary['deleted'])) + ', deferred=' + str(len(summary['deferred'])) +
        ', unresolved=' + str(len(summary['unresolved'])) + ', recycled=' + str(summary['recycled']))
    log('LOGS: ' + str(logdir))
sys.exit(1 if summary['unresolved'] or summary['deferred'] or summary['running_dropped'] else 0)
PY
