#!/bin/zsh
set -x
REC=/Users/matslucadagott/Documents/4_Projekte/01_Aktiv/LatexTerm/demo-video/recordings/take1.mov
LT=/opt/homebrew/bin/latexterm

# newest pane index = pane whose cwd matches, fallback: highest index
pane_for() {
  $LT list-panes --json | /usr/bin/python3 -c "
import json,sys
d=json.load(sys.stdin); target=sys.argv[1]
m=[p['index'] for p in d['panes'] if p['cwd']==target]
print(m[0] if m else max(p['index'] for p in d['panes']))
" "$1"
}

prompt_pane() { # $1 = pane index, rest = prompt
  local idx=$1; shift
  $LT send --pane "$idx" "$@"
  sleep 1.5
  $LT send --pane "$idx" ' '
}

$LT focus --pane 1
sleep 1
/usr/sbin/screencapture -v -R 0,34,1512,948 -V 150 "$REC" &
RECPID=$!
sleep 4

$LT new-pane --cwd "$HOME/Documents/9_Temp/demo-coffee" --exec "yolo --model sonnet"
sleep 7
P2=$(pane_for "$HOME/Documents/9_Temp/demo-coffee")
prompt_pane "$P2" "Create a landing page for a specialty coffee brand"
sleep 8

$LT new-pane --cwd "$HOME/Documents/9_Temp/demo-api" --exec "yolo --model sonnet"
sleep 7
P3=$(pane_for "$HOME/Documents/9_Temp/demo-api")
prompt_pane "$P3" "Fix the failing tests"
sleep 8

$LT new-pane --cwd "$HOME/Documents/9_Temp/demo-snake" --exec "yolo --model sonnet"
sleep 7
P4=$(pane_for "$HOME/Documents/9_Temp/demo-snake")
prompt_pane "$P4" "Build a playable retro snake game in Python"
sleep 2

$LT focus --pane 1
wait $RECPID
echo "RECORDING DONE"
ls -lh "$REC"
