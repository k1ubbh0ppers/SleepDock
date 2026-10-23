#!/bin/bash
# Probe SwiftUI before the full build: some Command Line Tools installations
# expose a newer SDK without shipping its required SwiftUI macro plugin.
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
probe_dir="$project_dir/.build/sdk-probe"
mkdir -p "$probe_dir"
cat > "$probe_dir/main.swift" <<'SWIFT'
import SwiftUI
struct SDKProbe: View {
    @State private var value = false
    var body: some View { Text(value ? "awake" : "sleep") }
}
SWIFT
default_sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
candidates=("${SLEEPDOCK_MACOS_SDK:-$default_sdk}")
if [ -z "${SLEEPDOCK_MACOS_SDK:-}" ]; then
    for candidate in "$(dirname "$default_sdk")"/MacOSX*.sdk; do
        [ -d "$candidate" ] && candidates+=("$candidate")
    done
fi
tried=''
for candidate in "${candidates[@]}"; do
    [ -d "$candidate" ] || continue
    candidate=$(cd "$candidate" && pwd -P)
    case "$tried" in *"|$candidate|"*) continue ;; esac
    tried="$tried|$candidate|"
    if /usr/bin/swiftc -typecheck -swift-version 5 -target arm64-apple-macosx14.0 \
        -sdk "$candidate" -module-cache-path "$probe_dir/cache" \
        "$probe_dir/main.swift" > "$probe_dir/diagnostics.log" 2>&1; then
        printf 'Selected compatible macOS SDK: %s\n' "$candidate" >&2
        printf '%s\n' "$candidate"
        exit 0
    fi
done
cat "$probe_dir/diagnostics.log" >&2 2>/dev/null || true
printf 'No compatible SwiftUI SDK found. Select a complete Xcode toolchain, or set SLEEPDOCK_MACOS_SDK to a compatible installed SDK.\n' >&2
exit 1
