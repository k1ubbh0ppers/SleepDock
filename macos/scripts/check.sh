#!/bin/bash
set -euo pipefail
project_dir=$(cd "$(dirname "$0")/.." && pwd)
check_dir="$project_dir/.build/checks"
sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)
mkdir -p "$check_dir"
/usr/bin/swiftc -sdk "$sdk" -swift-version 5 "$project_dir/Sources/Types.swift" "$project_dir/Sources/Policy.swift" \
    "$project_dir/Sources/AutoSleepGate.swift" "$project_dir/Tests/main.swift" -o "$check_dir/policy-checks"
"$check_dir/policy-checks"
/usr/bin/swiftc -sdk "$sdk" -swift-version 5 "$project_dir/Sources/Types.swift" "$project_dir/Sources/AgentMonitor.swift" \
    "$project_dir/Tests/AgentMonitorChecks.swift" -o "$check_dir/agent-checks"
"$check_dir/agent-checks"
/usr/bin/swiftc -sdk "$sdk" -swift-version 5 "$project_dir/Sources/Types.swift" "$project_dir/Sources/AgentCompletionTracker.swift" \
    "$project_dir/Tests/AgentCompletionChecks.swift" -o "$check_dir/completion-checks"
"$check_dir/completion-checks"
/usr/bin/swiftc -sdk "$sdk" -swift-version 5 "$project_dir/Sources/WidgetWindowSizing.swift" \
    "$project_dir/Tests/WindowSizingChecks.swift" -o "$check_dir/window-checks"
"$check_dir/window-checks"
/bin/bash -n "$project_dir/Resources/lid-watchdog.sh"
/usr/bin/python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read()); print("PASS 通用命令脚本语法")' "$project_dir/Resources/sleepdock-run"
/usr/bin/python3 "$project_dir/Tests/LidGuardChecks.py" "$check_dir/lid"
