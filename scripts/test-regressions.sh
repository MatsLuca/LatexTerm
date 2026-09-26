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
run_test launcher-palette-input LatexTerm/LauncherSearch.swift LatexTerm/LauncherSearchField.swift LatexTerm/LauncherPalette.swift LatexTerm/Theme/LineStyle.swift LatexTerm/Theme/LineControls.swift
run_test attention-note LatexTerm/AttentionNote.swift
run_test vm-quit LatexTerm/VMQuitGuard.swift
run_test agent-session LatexTerm/AgentSession.swift
run_test control-router LatexTerm/Control/ControlProtocol.swift LatexTerm/Control/PaneLayoutTree.swift LatexTerm/Control/ControlRouter.swift
run_test mcp-server LatexTerm/Control/ControlProtocol.swift LatexTerm/Control/PaneLayoutTree.swift LatexTermCLI/ControlClient.swift LatexTermCLI/MCPServer.swift
run_test pane-layout LatexTerm/Control/PaneLayoutTree.swift LatexTerm/Layout/PaneLayoutEngine.swift
run_test boards LatexTerm/Boards/BoardList.swift LatexTerm/Boards/BoardNamer.swift
run_test scratch-svg LatexTerm/Panes/Contents/ScratchSVG.swift
run_test scratch-layout LatexTerm/Panes/Contents/ScratchLayout.swift
run_test session-restore LatexTerm/SessionStore.swift LatexTerm/Control/ControlProtocol.swift LatexTerm/Control/PaneLayoutTree.swift LatexTerm/AgentSession.swift LatexTerm/AppRelaunch.swift
run_test board-file LatexTerm/Boards/BoardFile.swift LatexTerm/SessionStore.swift LatexTerm/Control/ControlProtocol.swift LatexTerm/Control/PaneLayoutTree.swift LatexTerm/AgentSession.swift LatexTerm/AppRelaunch.swift
run_test myzel-model LatexTerm/Panes/Contents/Myzel/MyzelModel.swift LatexTerm/Panes/Contents/Myzel/MyzelConfig.swift
run_test myzel-sse LatexTerm/Panes/Contents/Myzel/MyzelSSE.swift
run_test myzel-markdown LatexTerm/Panes/Contents/Myzel/MyzelMarkdown.swift
run_test myzel-compose LatexTerm/Panes/Contents/Myzel/MyzelCompose.swift
run_test myzel-jobs LatexTerm/Panes/Contents/Myzel/MyzelModel.swift LatexTerm/Panes/Contents/Myzel/MyzelJobs.swift
run_test myzel-launch LatexTerm/Panes/Contents/Myzel/MyzelLaunch.swift LatexTerm/Panes/Contents/Myzel/MyzelConfig.swift
run_test myzel-sandbox LatexTerm/Panes/Contents/Myzel/MyzelSandbox.swift LatexTerm/Panes/Contents/Myzel/MyzelJobs.swift LatexTerm/Panes/Contents/Myzel/MyzelModel.swift LatexTerm/Panes/Contents/Myzel/MyzelLaunch.swift LatexTerm/Panes/Contents/Myzel/MyzelConfig.swift
run_test myzel-transcript LatexTerm/Panes/Contents/Myzel/MyzelTranscript.swift
python3 -m unittest discover -s scripts/tests -v
