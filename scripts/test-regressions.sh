#!/bin/bash
# Same standalone regression checks locally and in CI. AppKit windows stay off-screen;
# VM tests use temporary helpers and never inspect or suspend the user's VM.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/latexterm-regressions.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT

run_test() {
    local name=$1
    shift
    echo "Testing $name"
    xcrun swiftc -Onone "$@" "scripts/test-$name.swift" -o "$test_dir/$name"
    "$test_dir/$name"
}

run_test launcher-search LatexTerm/LauncherSearch.swift
run_test codex-launch LatexTerm/CodexLaunchReadiness.swift
run_test home-session-scope LatexTerm/HomeSessionScope.swift
run_test launcher-search-focus LatexTerm/LauncherSearchField.swift
run_test launcher-palette-input LatexTerm/LauncherSearch.swift LatexTerm/LauncherSearchField.swift LatexTerm/LauncherPalette.swift
run_test vm-quit LatexTerm/VMQuitGuard.swift
run_test agent-session LatexTerm/AgentSession.swift
run_test control-router LatexTerm/Control/ControlProtocol.swift LatexTerm/Control/ControlRouter.swift
run_test session-restore LatexTerm/SessionStore.swift LatexTerm/AgentSession.swift LatexTerm/AppRelaunch.swift
python3 -m unittest discover -s scripts/tests -v
