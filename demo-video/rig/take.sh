#!/bin/zsh
# take.sh start NAME | stop — runs record + statelog in the background for the demo window.
R=${0:A:h}; T=${0:A:h}/../recordings/takes; mkdir -p $T
case $1 in
  start)
    WIN=$(swift $R/../scripts/winbounds.swift 2>/dev/null | grep -o 'id=[0-9]*' | head -1 | cut -d= -f2)
    [[ -n $2 ]] || { echo "name?"; exit 2; }
    WIN=${DEMO_WIN:-$WIN}
    nohup $R/record $T/$2.mov --window-id $WIN > $T/$2.rec.log 2>&1 & echo $! > $T/.rec.pid
    nohup python3 $R/statelog.py $T/$2.jsonl --window-id $WIN > /dev/null 2>&1 & echo $! > $T/.log.pid
    echo $2 > $T/.current; sleep 1; cat $T/$2.rec.log ;;
  stop)
    kill -INT $(cat $T/.rec.pid) 2>/dev/null; kill -TERM $(cat $T/.log.pid) 2>/dev/null; sleep 2
    N=$(cat $T/.current); tail -1 $T/$N.rec.log; wc -l < $T/$N.jsonl ;;
esac
