#!/bin/bash
# Privileged, fixed-purpose guard. No sourced files or user-provided commands.
# Usage: lid-watchdog.sh CONSOLE_APP_PID CONSOLE_UID RANDOM_UUID
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C
umask 022

[ "$(/usr/bin/id -u)" = 0 ] || exit 77
[ "$#" = 3 ] || exit 64
app_pid=$1
console_uid=$2
token=$3
case "$app_pid" in ''|*[!0-9]*) exit 64 ;; esac
case "$console_uid" in ''|*[!0-9]*) exit 64 ;; esac
case "$token" in ''|*[!A-Fa-f0-9-]*) exit 64 ;; esac
[ "${#token}" = 36 ] || exit 64
[ "$app_pid" -gt 1 ] && [ "$console_uid" -gt 0 ] || exit 64

base='/Library/Application Support/com.phecda.SleepDock'
root="$base/LidGuard"
state="$root/state"
lock="$root/lock"
mutex="$root/guard.flock"
lease="/tmp/com.phecda.SleepDock-lid-$console_uid-$token.lease"

# Never write through a symlink or accept a non-root-owned state directory.
for directory in "$base" "$root"; do
    [ ! -L "$directory" ] || exit 78
    if [ ! -e "$directory" ]; then
        /bin/mkdir "$directory" || exit 78
        /usr/sbin/chown root:wheel "$directory" || exit 78
        /bin/chmod 0755 "$directory" || exit 78
    fi
    [ -d "$directory" ] && [ "$(/usr/bin/stat -f %u "$directory")" = 0 ] || exit 78
    # Root-owned state must not be writable by other users.
    /bin/chmod 0755 "$directory" || exit 78
done
[ ! -L "$state" ] && [ ! -L "$lock" ] && [ ! -L "$mutex" ] || exit 78
if [ -e "$state" ]; then
    [ -f "$state" ] && [ "$(/usr/bin/stat -f %u "$state")" = 0 ] && \
        [ "$(/usr/bin/stat -f %l "$state")" = 1 ] || exit 78
fi
if [ -e "$mutex" ]; then
    [ -f "$mutex" ] && [ "$(/usr/bin/stat -f %u "$mutex")" = 0 ] && \
        [ "$(/usr/bin/stat -f %l "$mutex")" = 1 ] || exit 78
fi
# lockf keeps the advisory lock on this inherited file description until the
# shell exits, including SIGKILL. Never unlink this inode while a guard runs.
exec 9>>"$mutex" || exit 78
/bin/chmod 0600 "$mutex" || exit 78
/usr/bin/lockf -s -t 15 9 || exit 75

current_disabled() { /usr/bin/pmset -g | /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }'; }
read_field() { /usr/bin/sed -n "s/^$1=//p" "$state" 2>/dev/null | /usr/bin/head -n 1; }
process_start() { /bin/ps -p "$1" -o lstart= | /usr/bin/sed 's/^ *//;s/ *$//'; }
app_start=$(/bin/ps -p "$app_pid" -o lstart= | /usr/bin/sed 's/^ *//;s/ *$//')
app_owner=$(/bin/ps -p "$app_pid" -o uid= | /usr/bin/tr -d ' ')
[ -n "$app_start" ] && [ "$app_owner" = "$console_uid" ] || exit 69

write_record() {
    temporary="$root/state.$$"
    # This directory is root-only writable; atomic replace never follows a user link.
    if ! printf 'token=%s\napp_pid=%s\nguard_pid=%s\nguard_start=%s\noriginal=%s\nstatus=%s\nupdated=%s\n' \
        "$2" "$3" "$4" "$5" "$6" "$1" "$(/bin/date +%s)" > "$temporary" || \
        ! /bin/chmod 0644 "$temporary" || ! /bin/mv -f "$temporary" "$state"; then
        /bin/rm -f "$temporary"
        return 1
    fi
}

old_guard_alive() {
    case "$old_guard_pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$old_guard_pid" -gt 1 ] && [ -n "$old_guard_start" ] || return 1
    /bin/kill -0 "$old_guard_pid" 2>/dev/null || return 1
    [ "$(process_start "$old_guard_pid")" = "$old_guard_start" ]
}

# Older releases used a directory lock. Let a live older guard restore and exit
# before touching its record. Current releases are serialized by lockf above.
if [ -d "$lock" ]; then
    [ "$(/usr/bin/stat -f %u "$lock")" = 0 ] || exit 78
    old_guard_pid=$(/bin/cat "$lock/pid" 2>/dev/null || true)
    old_guard_start=$(/bin/cat "$lock/start" 2>/dev/null || true)
    attempts=0
    while old_guard_alive; do
        [ "$attempts" -lt 15 ] || exit 75
        /bin/sleep 1
        attempts=$((attempts + 1))
    done
    /bin/rm -f "$lock/pid" "$lock/start"
    [ ! -d "$lock" ] || /bin/rmdir "$lock" || exit 78
elif [ -e "$lock" ]; then
    exit 78
fi
if [ -f "$state" ]; then
    old_status=$(read_field status)
    if [ "$old_status" = active ] || [ "$old_status" = preparing ] || [ "$old_status" = error ]; then
        old_original=$(read_field original)
        case "$old_original" in 0|1) ;; *) exit 78 ;; esac
        old_token=$(read_field token)
        old_app_pid=$(read_field app_pid)
        old_guard_pid=$(read_field guard_pid)
        old_guard_start=$(read_field guard_start)
        if /usr/bin/pmset -a disablesleep "$old_original" && [ "$(current_disabled)" = "$old_original" ]; then
            write_record restored "$old_token" "$old_app_pid" "$old_guard_pid" "$old_guard_start" "$old_original" || exit 74
        else
            write_record error "$old_token" "$old_app_pid" "$old_guard_pid" "$old_guard_start" "$old_original" || true
            exit 74
        fi
    elif [ "$old_status" != restored ]; then
        # A corrupted record must never become a new baseline silently.
        exit 78
    fi
fi

lease_alive() {
    /bin/kill -0 "$app_pid" 2>/dev/null || return 1
    [ "$(process_start "$app_pid")" = "$app_start" ] || return 1
    [ "$(/bin/ps -p "$app_pid" -o uid= | /usr/bin/tr -d ' ')" = "$console_uid" ] || return 1
    # stat defaults to lstat on macOS. Read metadata in one call, never open
    # user-controlled contents (which could otherwise race into a FIFO/link).
    lease_metadata=$(/usr/bin/stat -f '%HT|%u|%m' "$lease" 2>/dev/null) || return 1
    IFS='|' read -r lease_kind lease_owner modified <<< "$lease_metadata"
    [ "$lease_kind" = 'Regular File' ] && [ "$lease_owner" = "$console_uid" ] || return 1
    now=$(/bin/date +%s)
    case "$modified" in ''|*[!0-9]*) return 1 ;; esac
    elapsed=$((now - modified))
    [ "$elapsed" -ge 0 ] && [ "$elapsed" -le 12 ]
}

# Cancellation during a slow authorization must not briefly change the system.
lease_alive || exit 69
original=$(current_disabled)
case "$original" in 0|1) ;; *) exit 70 ;; esac
guard_start=$(process_start "$$")
[ -n "$guard_start" ] || exit 69
/bin/mkdir -m 0700 "$lock" || exit 75
if ! printf '%s\n' "$$" > "$lock/pid" || ! printf '%s\n' "$guard_start" > "$lock/start"; then
    /bin/rm -f "$lock/pid" "$lock/start"
    /bin/rmdir "$lock" 2>/dev/null || true
    exit 78
fi
write_state() { write_record "$1" "$token" "$app_pid" "$$" "$guard_start" "$original"; }
cleanup_started=0
must_restore=0
cleanup() {
    [ "$cleanup_started" = 0 ] || return
    cleanup_started=1
    if [ "$must_restore" = 1 ]; then
        if /usr/bin/pmset -a disablesleep "$original" && [ "$(current_disabled)" = "$original" ]; then
            write_state restored || true
        else
            write_state error || true
        fi
    fi
    /bin/rm -f "$lock/pid" "$lock/start"
    /bin/rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' HUP INT TERM
# Snapshot exists before any mutation. Hard-kill recovery uses this record next launch.
write_state preparing || exit 74
must_restore=1
/usr/bin/pmset -a disablesleep 1 || exit 74
[ "$(current_disabled)" = 1 ] || exit 74
write_state active || exit 74

while lease_alive; do
    /bin/sleep 2
done
exit 0
