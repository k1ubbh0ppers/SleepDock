#!/bin/sh
# The inhibitor owns only a temporary logind FD. Never edit system configuration.
set -eu
parent="$1"
lease="$2"
token="$3"
case "$parent" in ''|*[!0-9]*) exit 2;; esac
case "$token" in ''|*[!a-fA-F0-9-]*) exit 2;; esac
parent_start() {
    line=$(cat "/proc/$parent/stat") || return 1
    rest=${line##*) }
    set -- $rest
    [ "$#" -ge 20 ] || return 1
    shift 19
    printf '%s' "$1"
}
initial=$(parent_start) || exit 3
valid_lease() {
    [ -f "$lease" ] && [ ! -L "$lease" ] || return 1
    IFS= read -r current < "$lease" || return 1
    [ "$current" = "$token" ] || return 1
    modified=$(stat -c %Y -- "$lease") || return 1
    now=$(date +%s)
    [ "$modified" -le "$((now + 5))" ] && [ "$((now - modified))" -le 15 ]
}
valid_lease || exit 4
printf 'SLEEPDOCK_INHIBIT_READY\n'
while valid_lease && [ "$(parent_start 2>/dev/null || true)" = "$initial" ]; do
    sleep 2
done
# Exiting releases the inhibitor even after the Electron parent has crashed.
exit 0
