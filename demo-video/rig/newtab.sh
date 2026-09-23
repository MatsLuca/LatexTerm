#!/bin/zsh
# newtab.sh DIR [CMD] — fresh demo tab: ⇧⌘T, one terminal pane in DIR running CMD
# (default: demo-claude), Home pane closed, tab moved into its own window (so the tab bar shows only
# the demo). Prints the window id for take.sh (frontmost LatexTerm window).
R=${0:A:h}
osascript -e 'tell application "LatexTerm" to activate'; sleep 0.4
$R/input key cmd+shift+t; sleep 1.5
env -u LATEXTERM_PANE_ID latexterm new-pane --cwd "$1" --exec "${2:-$HOME/Projects/.demo-bin/demo-claude}"
sleep 0.8
home=$(latexterm list-panes --json | python3 -c "import json,sys; print(next((p['id'][:8] for p in json.load(sys.stdin)['panes'] if p['kind']=='home'),''))")
[[ -n $home ]] && latexterm close-pane --pane $home --force
osascript -e 'tell application "System Events" to tell process "LatexTerm" to click menu item "Move Tab to New Window" of menu 1 of menu bar item "Window" of menu bar 1' >/dev/null
sleep 1
swift $R/../scripts/winbounds.swift 2>/dev/null | grep -o 'id=[0-9]*' | head -1 | cut -d= -f2
