#!/bin/zsh
# wait.sh PANE [MAX_S] — waits until the agent in PANE has taken the prompt and finished its turn.
for i in {1..${2:-400}}; do
  s=$(latexterm list-panes --json | python3 -c "import json,sys; print(next((p.get('state') for p in json.load(sys.stdin)['panes'] if p['index']==$1),'gone'))")
  [[ $s == working ]] && seen=1
  [[ -n $seen && $s != working ]] && { echo "done after ${i}s ($s)"; exit 0; }
  sleep 1
done; echo "timeout ($s)"; exit 1
